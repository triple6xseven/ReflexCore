use crate::local_files as scope;
#[cfg(test)]
mod tests;
use crate::task_integrity::{self, Fault};
use scope::Directory;
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    error::Error,
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    os::windows::fs::OpenOptionsExt,
    path::{Path, PathBuf},
    time::{Instant, SystemTime, UNIX_EPOCH},
};

type Result<T> = std::result::Result<T, Fault>;

const MAX_CHECKLIST: u64 = 512 * 1024;
const MAX_REPORT: u64 = 4 * 1024 * 1024;
#[derive(Deserialize, Serialize, PartialEq, Debug)]
#[serde(deny_unknown_fields)]
struct Entry {
    path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    sha256: Option<String>,
}
#[derive(Deserialize, Serialize, PartialEq, Debug)]
#[serde(deny_unknown_fields)]
struct Checklist {
    schema: String,
    name: String,
    files: Vec<Entry>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    folder: PathBuf,
    checklist: PathBuf,
    report: PathBuf,
    #[serde(default)]
    checklist_sha256: Option<String>,
}
#[derive(Deserialize, Serialize, PartialEq, Debug)]
#[serde(rename_all = "snake_case")]
enum Status {
    Present,
    Missing,
    Unreadable,
    Mismatched,
    Changed,
}
#[derive(Deserialize, Serialize, PartialEq, Debug)]
#[serde(deny_unknown_fields)]
struct Finding {
    status: Status,
    #[serde(skip_serializing_if = "Option::is_none")]
    observed_sha256: Option<String>,
}
impl Finding {
    fn only(status: Status) -> Self {
        Self {
            status,
            observed_sha256: None,
        }
    }
}
#[derive(Deserialize, Serialize, PartialEq, Debug)]
#[serde(deny_unknown_fields)]
struct Report {
    schema: String,
    run_id: String,
    checklist: Checklist,
    results: Vec<Finding>,
    verdict: String,
}
#[derive(Default, Serialize)]
struct Metrics {
    queue_wait_us: Option<u64>,
    worker_startup_us: Option<u64>,
    check_us: u64,
    write_us: u64,
    readback_us: u64,
    worker_us: u64,
    bytes_hashed: u64,
    peak_private_bytes: Option<usize>,
    model_calls: u32,
}
fn elapsed(start: Instant) -> u64 {
    start.elapsed().as_micros() as u64
}
static INTERRUPTED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
unsafe extern "system" fn on_console_event(event: u32) -> windows::core::BOOL {
    if event <= 1 {
        INTERRUPTED.store(true, std::sync::atomic::Ordering::Relaxed);
        true.into()
    } else {
        false.into()
    }
}
fn stopped() -> bool {
    INTERRUPTED.load(std::sync::atomic::Ordering::Relaxed)
        || task_integrity::cancelled()
        || task_integrity::guard_cancelled()
}
fn cancel() -> Result<()> {
    if stopped() {
        Err(Fault::Cancelled)
    } else {
        Ok(())
    }
}
fn bounded(file: File, limit: u64) -> io::Result<Vec<u8>> {
    let mut b = Vec::new();
    file.take(limit + 1).read_to_end(&mut b)?;
    if b.len() as u64 > limit {
        return Err(io::ErrorKind::InvalidData.into());
    }
    Ok(b)
}
fn private_bytes(path: &Path, limit: u64) -> Result<Vec<u8>> {
    let file = scope::open_for_readback(path).map_err(|_| Fault::PreconditionFailed)?;
    bounded(file, limit).map_err(|_| Fault::PreconditionFailed)
}
fn private_json<T: serde::de::DeserializeOwned>(path: &Path, limit: u64) -> Result<T> {
    decode(&private_bytes(path, limit)?)
}
fn decode<T: serde::de::DeserializeOwned>(bytes: &[u8]) -> Result<T> {
    serde_json::from_slice(bytes.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(bytes))
        .map_err(|_| Fault::PreconditionFailed)
}
fn validate(c: &Checklist) -> Result<()> {
    let mut seen = HashSet::new();
    if c.schema != "reflexcore.handoff.checklist.v1"
        || c.name.trim().is_empty()
        || c.name.len() > 128
        || c.files.is_empty()
        || c.files.len() > 1024
    {
        return Err(Fault::PreconditionFailed);
    }
    for e in &c.files {
        scope::relative(&e.path).map_err(|_| Fault::PreconditionFailed)?;
        if !seen.insert(e.path.replace('/', "\\").to_uppercase())
            || e.sha256
                .as_ref()
                .is_some_and(|h| h.len() != 64 || !h.bytes().all(|x| x.is_ascii_hexdigit()))
        {
            return Err(Fault::PreconditionFailed);
        }
    }
    Ok(())
}
fn classify(err: io::Error) -> Result<Finding> {
    match err.kind() {
        io::ErrorKind::InvalidInput => Err(Fault::PreconditionFailed),
        io::ErrorKind::NotFound => Ok(Finding::only(Status::Missing)),
        _ => Ok(Finding::only(Status::Unreadable)),
    }
}
fn digest(file: &mut File, length: u64, m: &mut Metrics) -> Result<Option<String>> {
    let mut file = file.take(length);
    let mut buf = [0u8; 65536];
    let mut hash = Sha256::new();
    loop {
        cancel()?;
        match file.read(&mut buf) {
            Ok(0) if file.limit() != 0 => return Ok(None),
            Ok(0) => break,
            Ok(n) => {
                fixture_checkpoint("hashing");
                hash.update(&buf[..n]);
                m.bytes_hashed += n as u64;
            }
            Err(_) => return Ok(None),
        }
    }
    Ok(Some(format!("{:x}", hash.finalize())))
}
fn inspect(root: &Directory, boundary: &Path, e: &Entry, m: &mut Metrics) -> Result<Finding> {
    let relative = Path::new(&e.path);
    let parent = match root.child_parent(relative) {
        Ok(dir) => dir,
        Err(err) => return classify(err),
    };
    let path = parent
        .path
        .join(relative.file_name().ok_or(Fault::PreconditionFailed)?);
    let expected = e.sha256.as_deref();
    // The usual path pins a stable file with a single open and one streaming pass.
    // If a writer is active, take an optimistic sample and reconcile it under a read lock.
    let (mut file, contended) = match scope::open(&path, expected.is_some(), 1) {
        Ok(f) => (f, false),
        Err(err) if err.raw_os_error() == Some(32) => {
            match scope::open(&path, expected.is_some(), 3) {
                Ok(f) => (f, true),
                Err(err) => return classify(err),
            }
        }
        Err(err) => return classify(err),
    };
    let actual = scope::physical(&file).map_err(|_| Fault::PreconditionFailed)?;
    if !actual.starts_with(boundary) {
        return Err(Fault::PreconditionFailed);
    }
    let Ok(before) = file.metadata() else {
        return Ok(Finding::only(Status::Unreadable));
    };
    if !before.is_file() {
        return Ok(Finding::only(Status::Unreadable));
    }
    let observed = if expected.is_some() {
        match digest(&mut file, before.len(), m)? {
            Some(h) => Some(h),
            None => return Ok(Finding::only(Status::Unreadable)),
        }
    } else {
        None
    };
    if contended {
        fixture_checkpoint("sampled");
        let Ok(after) = file.metadata() else {
            return Ok(Finding::only(Status::Unreadable));
        };
        if before.len() != after.len() || before.modified().ok() != after.modified().ok() {
            return Ok(Finding::only(Status::Changed));
        }
        let Ok(mut stable) = scope::open(&path, expected.is_some(), 1) else {
            return Ok(Finding::only(Status::Unreadable));
        };
        let Ok(locked) = stable.metadata() else {
            return Ok(Finding::only(Status::Unreadable));
        };
        if before.len() != locked.len() || before.modified().ok() != locked.modified().ok() {
            return Ok(Finding::only(Status::Changed));
        }
        if expected.is_some() {
            match digest(&mut stable, before.len(), m)? {
                None => return Ok(Finding::only(Status::Unreadable)),
                Some(h) if Some(&h) != observed.as_ref() => {
                    return Ok(Finding::only(Status::Changed))
                }
                _ => {}
            }
        }
    }
    let mismatch = expected
        .zip(observed.as_deref())
        .is_some_and(|(a, b)| !a.eq_ignore_ascii_case(b));
    Ok(Finding {
        status: if mismatch {
            Status::Mismatched
        } else {
            Status::Present
        },
        observed_sha256: observed,
    })
}
struct Stage(Option<PathBuf>);
impl Drop for Stage {
    fn drop(&mut self) {
        if let Some(path) = self.0.take() {
            let _ = fs::remove_file(path);
        }
    }
}
fn readback(path: &Path, expected: &Report) -> Result<File> {
    let file = scope::open(path, true, 1).map_err(|_| Fault::VerificationFailed)?;
    let bytes = bounded(
        file.try_clone().map_err(|_| Fault::Infrastructure)?,
        MAX_REPORT,
    )
    .map_err(|_| Fault::VerificationFailed)?;
    let report: Report = serde_json::from_slice(&bytes).map_err(|_| Fault::VerificationFailed)?;
    if &report != expected {
        return Err(Fault::VerificationFailed);
    }
    Ok(file)
}
fn execute(
    req: Request,
    id: &str,
    m: &mut Metrics,
    summary: &mut Option<serde_json::Value>,
) -> Result<()> {
    cancel()?;
    let start = Instant::now();
    let bytes = private_bytes(&req.checklist, MAX_CHECKLIST)?;
    if let Some(expected) = &req.checklist_sha256 {
        if !expected.eq_ignore_ascii_case(&format!("{:x}", Sha256::digest(&bytes))) {
            return Err(Fault::PreconditionFailed);
        }
    }
    let c: Checklist = decode(&bytes)?;
    validate(&c)?;
    let root = Directory::local(&req.folder).map_err(|_| Fault::PreconditionFailed)?;
    let (_out_pin, out) = scope::target(&req.report).map_err(|_| Fault::PreconditionFailed)?;
    if out.try_exists().map_err(|_| Fault::PreconditionFailed)? {
        return Err(Fault::PreconditionFailed);
    }
    let boundary = root.physical().map_err(|_| Fault::PreconditionFailed)?;
    let mut results = Vec::with_capacity(c.files.len());
    for entry in &c.files {
        cancel()?;
        if root
            .path
            .join(&entry.path)
            .to_string_lossy()
            .replace('/', "\\")
            .to_uppercase()
            == out.to_string_lossy().to_uppercase()
        {
            return Err(Fault::PreconditionFailed);
        }
        results.push(inspect(&root, &boundary, entry, m)?);
    }
    let ready = results.iter().all(|r| r.status == Status::Present);
    let incomplete = results
        .iter()
        .any(|r| matches!(r.status, Status::Changed | Status::Unreadable));
    let report = Report {
        schema: "reflexcore.handoff.report.v1".into(),
        run_id: id.into(),
        checklist: c,
        results,
        verdict: if ready { "Ready" } else { "Needs attention" }.into(),
    };
    m.check_us = elapsed(start);
    cancel()?;
    let start = Instant::now();
    let tmp = out.with_file_name(format!(".reflex-handoff-{id}.tmp"));
    let mut stage;
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .share_mode(0)
        .open(&tmp)
        .map_err(|_| Fault::Infrastructure)?;
    stage = Stage(Some(tmp.clone()));
    let encoded = serde_json::to_vec_pretty(&report).map_err(|_| Fault::Infrastructure)?;
    if encoded.len() as u64 > MAX_REPORT {
        return Err(Fault::PreconditionFailed);
    }
    file.write_all(&encoded)
        .and_then(|_| file.sync_all())
        .map_err(|_| Fault::Infrastructure)?;
    drop(file);
    m.write_us = elapsed(start);
    fixture_checkpoint("staged");
    let start = Instant::now();
    drop(readback(&tmp, &report)?);
    m.readback_us = elapsed(start);
    cancel()?;
    let start = Instant::now();
    scope::publish(&tmp, &out).map_err(|_| Fault::PreconditionFailed)?;
    stage.0.take();
    m.write_us += elapsed(start);
    let start = Instant::now();
    let _published = readback(&out, &report)?;
    m.readback_us += elapsed(start);
    if stopped() {
        return Err(Fault::CancelledUnknown);
    }
    let mut counts = [0; 5];
    for finding in &report.results {
        counts[match finding.status {
            Status::Present => 0,
            Status::Missing => 1,
            Status::Mismatched => 2,
            Status::Unreadable => 3,
            Status::Changed => 4,
        }] += 1;
    }
    *summary = Some(
        json!({"ready":ready,"present":counts[0],"missing":counts[1],
        "mismatched":counts[2],"unreadable":counts[3],"changed":counts[4]}),
    );
    if incomplete {
        Err(Fault::EffectUnknown)
    } else {
        Ok(())
    }
}
#[cfg(not(test))]
fn fixture_checkpoint(_: &str) {}
#[cfg(test)]
fn fixture_checkpoint(stage: &str) {
    if std::env::var("HANDOFF_TEST_STAGE").as_deref() != Ok(stage) {
        return;
    }
    fs::write("reached", stage).unwrap();
    let deadline = Instant::now() + std::time::Duration::from_secs(10);
    while !Path::new("resume").exists() {
        assert!(Instant::now() < deadline);
        std::thread::sleep(std::time::Duration::from_millis(2));
    }
}
fn peak_private() -> Option<usize> {
    use windows::Win32::System::{
        ProcessStatus::{GetProcessMemoryInfo, PROCESS_MEMORY_COUNTERS},
        Threading::GetCurrentProcess,
    };
    let size = std::mem::size_of::<PROCESS_MEMORY_COUNTERS>() as u32;
    let mut counters = PROCESS_MEMORY_COUNTERS {
        cb: size,
        ..Default::default()
    };
    unsafe { GetProcessMemoryInfo(GetCurrentProcess(), &mut counters, size) }.ok()?;
    Some(counters.PeakPagefileUsage)
}
pub(crate) fn run(args: &[String]) -> std::result::Result<(), Box<dyn Error>> {
    let clock = Instant::now();
    let entered = SystemTime::now().duration_since(UNIX_EPOCH)?.as_micros() as u64;
    if std::env::var_os("REFLEXCORE_QUEUE_MANIFEST").is_none() {
        unsafe {
            windows::Win32::System::Console::SetConsoleCtrlHandler(Some(on_console_event), true)
        }?;
    }
    let task = task_integrity::task_id();
    let id = task.clone().unwrap_or_else(task_integrity::run_id);
    let mut m = Metrics::default();
    if let (Ok(a), Ok(b)) = (
        std::env::var("REFLEX_HANDOFF_SUBMIT_US"),
        std::env::var("REFLEX_HANDOFF_LAUNCH_US"),
    ) {
        if let (Ok(a), Ok(b)) = (a.parse::<u64>(), b.parse::<u64>()) {
            m.queue_wait_us = b.checked_sub(a);
            m.worker_startup_us = entered.checked_sub(b);
        }
    }
    let mut summary = None;
    let result = (|| {
        cancel()?;
        let req = match args {
            [mode] if mode == "--queued" && task.is_some() => private_json(
                &std::env::current_dir()
                    .map_err(|_| Fault::Infrastructure)?
                    .join(format!("data/private/handoff/{id}.json")),
                16384,
            )?,
            [folder, checklist, report] if task.is_none() => Request {
                folder: folder.into(),
                checklist: checklist.into(),
                report: report.into(),
                checklist_sha256: None,
            },
            [folder, checklist, report, flag, hash]
                if task.is_none() && flag == "--checklist-sha256" =>
            {
                Request {
                    folder: folder.into(),
                    checklist: checklist.into(),
                    report: report.into(),
                    checklist_sha256: Some(hash.clone()),
                }
            }
            _ => return Err(Fault::PreconditionFailed),
        };
        execute(req, &id, &mut m, &mut summary)
    })();
    m.worker_us = elapsed(clock);
    m.peak_private_bytes = peak_private();
    let (outcome, verification, reason) = match result {
        Ok(()) => ("verified", "verified", "disk_readback"),
        Err(Fault::EffectUnknown) => ("unverified", "unknown", "effect_unknown"),
        Err(Fault::Cancelled) => ("cancelled", "not_confirmed", "operator_cancelled"),
        Err(Fault::CancelledUnknown) => ("cancelled", "unknown", "cancelled_effect_unknown"),
        Err(e) => (
            "failed",
            if matches!(e, Fault::VerificationFailed) {
                "failed"
            } else {
                "not_confirmed"
            },
            e.code(),
        ),
    };
    let receipt = json!({"schema":"reflexcore.task.receipt.v1","task_id":id,"run_id":id,"stage":"handoff","outcome":outcome,
        "verification":verification,"reason":reason,"metrics":m,"handoff":summary});
    if task.is_some() {
        task_integrity::publish_receipt(&id, &id, &receipt)?;
    }
    println!("{}", receipt);
    result.map_err(Into::into)
}
