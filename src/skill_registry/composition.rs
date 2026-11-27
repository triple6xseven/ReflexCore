use super::saved_text::{self, Adapter, Binding, Evidence};
use crate::{local_files, task_integrity, Result};
use std::{
    fs::OpenOptions,
    io::{Read, Write},
    os::windows::fs::OpenOptionsExt,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{Duration, Instant},
};

#[derive(Clone, Copy, PartialEq, Debug)]
enum Port {
    Document,
    LiveText,
    Derived,
    Checked,
}
#[derive(Clone, Copy)]
struct Step {
    id: &'static str,
    version: u8,
    from: Option<usize>,
    input: Option<Port>,
    output: Port,
    permissions: u8,
}
const CREATE: u8 = 1;
const READ: u8 = 2;
const CONSUME: u8 = 4;
const DERIVE: u8 = 8;
const PUBLISH: u8 = 16;
const GRAPH: [Step; 4] = [
    Step {
        id: "editor.create_document",
        version: 1,
        from: None,
        input: None,
        output: Port::Document,
        permissions: CREATE,
    },
    Step {
        id: saved_text::ID,
        version: 1,
        from: Some(0),
        input: Some(Port::Document),
        output: Port::LiveText,
        permissions: READ,
    },
    Step {
        id: "artifact.derive_text",
        version: 1,
        from: Some(1),
        input: Some(Port::LiveText),
        output: Port::Derived,
        permissions: CONSUME | DERIVE,
    },
    Step {
        id: "artifact.verify_derived",
        version: 1,
        from: Some(2),
        input: Some(Port::Derived),
        output: Port::Checked,
        permissions: READ | PUBLISH,
    },
];
const CHAIN: [Step; 6] = [
    GRAPH[0],
    GRAPH[1],
    GRAPH[2],
    GRAPH[3],
    Step {
        from: Some(3),
        input: Some(Port::Checked),
        ..GRAPH[2]
    },
    Step {
        from: Some(4),
        ..GRAPH[3]
    },
];
fn preflight(graph: &[Step], grants: u8) -> Result<()> {
    if !(2..=8).contains(&graph.len()) || graph.last().map(|s| s.output) != Some(Port::Checked) {
        return Err("Invalid terminal port or size".into());
    }
    for (i, s) in graph.iter().enumerate() {
        let registered = GRAPH
            .iter()
            .find(|r| r.id == s.id && r.version == s.version)
            .ok_or("Unknown skill or version")?;
        let snapshot_input = registered.output == Port::Derived && s.input == Some(Port::Checked);
        if s.output != registered.output
            || (!snapshot_input && s.input != registered.input)
            || s.permissions != registered.permissions
            || grants & s.permissions != s.permissions
            || s.from != i.checked_sub(1)
            || s.input != i.checked_sub(1).map(|j| graph[j].output)
        {
            return Err("Incompatible or unauthorized skill edge".into());
        }
    }
    Ok(())
}
pub(crate) fn catalog() -> Vec<serde_json::Value> {
    [("editor.derive_copy",&GRAPH[..]),("editor.derive_chain",&CHAIN[..])].into_iter().map(|(id,steps)|
        serde_json::json!({"id":id,"version":1,"submission":"studio_approval","adapters":["winforms","winforms-background","notepad"],
            "permissions":["create","verify","consume","derive","publish"],
            "outputs":steps.iter().filter(|s|s.output==Port::Checked).count(),
            "steps":steps.iter().map(|s|serde_json::json!({"skill":s.id,"version":s.version,"depends_on":s.from,
                "input":s.input.map(|p|format!("{p:?}")),"output":format!("{:?}",s.output)})).collect::<Vec<_>>()})
    ).collect()
}
struct Staging {
    file: std::fs::File,
    path: PathBuf,
    published: bool,
}
impl Staging {
    fn publish(&mut self, output: &Path) -> Result<()> {
        use std::os::windows::{ffi::OsStrExt, io::AsRawHandle};
        use windows::Win32::{Foundation::HANDLE, Storage::FileSystem::*};
        let name: Vec<_> = output.as_os_str().encode_wide().collect();
        let size = std::mem::size_of::<FILE_RENAME_INFO>() + name.len() * 2;
        let mut words = vec![0usize; size.div_ceil(std::mem::size_of::<usize>())];
        let record = words.as_mut_ptr().cast::<FILE_RENAME_INFO>();
        // Aligned zeroed storage leaves ReplaceIfExists false; the flexible
        // UTF-16 name stays inside the allocation until the system call returns.
        unsafe {
            (*record).FileNameLength = (name.len() * 2) as u32;
            std::ptr::copy_nonoverlapping(
                name.as_ptr(),
                std::ptr::addr_of_mut!((*record).FileName).cast::<u16>(),
                name.len(),
            );
            SetFileInformationByHandle(
                HANDLE(self.file.as_raw_handle()),
                FileRenameInfo,
                record.cast(),
                size as u32,
            )
            .map_err(|_| "Exclusive publication failed")?;
        }
        self.published = true;
        Ok(())
    }
}
impl Drop for Staging {
    fn drop(&mut self) {
        if !self.published {
            use std::os::windows::io::AsRawHandle;
            use windows::Win32::{Foundation::HANDLE, Storage::FileSystem::*};
            let info = FILE_DISPOSITION_INFO { DeleteFile: true };
            unsafe {
                let _ = SetFileInformationByHandle(
                    HANDLE(self.file.as_raw_handle()),
                    FileDispositionInfo,
                    std::ptr::from_ref(&info).cast(),
                    std::mem::size_of_val(&info) as u32,
                );
            }
        }
    }
}
#[derive(Clone, Copy, PartialEq, Debug)]
enum Boundary {
    Launch,
    EditorAction,
    SourceVerified,
    StageCreate,
    StageWrite,
    Sync,
    Readback,
    Publish,
    Published,
    Terminal,
}

pub(crate) struct Plan {
    progress: Option<(PathBuf, String)>,
    graph: &'static [Step],
    second: Option<(PathBuf, String)>,
    stop_path: PathBuf,
    published: std::cell::Cell<u8>,
    #[cfg(test)]
    probe: Option<Box<dyn Fn(Boundary)>>,
    binding: &'static Binding,
    adapter: Adapter,
    grants: u8,
    deadline: Instant,
    started: std::time::SystemTime,
    _scope: local_files::Directory,
    output: PathBuf,
    suffix: String,
}
impl Plan {
    fn boundary(&self, _at: Boundary, index: usize) -> Result<()> {
        #[cfg(test)]
        if let Some(probe) = &self.probe {
            probe(_at);
        }
        self.check(index)
    }
    pub(crate) fn check_editor(&self) -> Result<()> {
        self.boundary(Boundary::EditorAction, 0)
    }
    fn progress(&self, index: usize) -> Result<()> {
        if let Some((path, attempt)) = &self.progress {
            let tmp = path.with_extension("progress.tmp");
            std::fs::write(
                &tmp,
                format!("{}\n{}\n{}", attempt, index + 1, self.graph[index].id),
            )?;
            std::fs::rename(tmp, path)?;
        }
        Ok(())
    }
    fn check(&self, index: usize) -> Result<()> {
        task_integrity::check_cancel()?;
        match std::fs::metadata(&self.stop_path) {
            Ok(meta) if meta.modified()? >= self.started => {
                return Err(task_integrity::Fault::Cancelled.into())
            }
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => {
                return Err("Stop state unavailable".into())
            }
            _ => {}
        }
        if Instant::now() >= self.deadline
            || self.grants & self.graph[index].permissions != self.graph[index].permissions
        {
            return Err("Composition deadline or permission rejected".into());
        }
        Ok(())
    }
    pub(crate) fn finish<'a>(&self, run: &'a str, text: &str) -> Result<Evidence<'a>> {
        enum Value<'a> {
            Document,
            Live(saved_text::VerifiedArtifact<'a>),
            Derived(Evidence<'a>, Staging, (u32, u32, u32), String),
            Checked(Evidence<'a>, String),
        }
        let mut value = Value::Document;
        let mut outputs = std::iter::once((&self.output, &self.suffix))
            .chain(self.second.iter().map(|(p, s)| (p, s)));
        let mut dest = &self.output;
        for (index, step) in self.graph.iter().enumerate().skip(1) {
            self.check(index)?;
            self.progress(index)?;
            value = match (step.output, value) {
                (Port::LiveText, Value::Document) => Value::Live(self.binding.artifact(run, text)?),
                (Port::Derived, input) => {
                    let (proof, mut expected) = match input {
                        Value::Live(source) => {
                            self.boundary(Boundary::SourceVerified, index)?;
                            let (proof, bytes) = source.consume(run, self.adapter)?;
                            if !self.binding.matches_snapshot(&bytes, text) {
                                return Err("Snapshot invalidated".into());
                            }
                            (proof, text.to_owned())
                        }
                        Value::Checked(proof, verified_text) => (proof, verified_text),
                        _ => return Err("Missing verified source".into()),
                    };
                    let (path, suffix) = outputs.next().ok_or("Output budget exhausted")?;
                    dest = path;
                    expected.push_str(suffix);
                    self.check(index)?;
                    let (writer, identity) = self.create(index, &expected)?;
                    Value::Derived(proof, writer, identity, expected)
                }
                (Port::Checked, Value::Derived(proof, mut writer, identity, expected)) => {
                    self.verify_output(index, &writer.path, identity, &expected)?;
                    self.boundary(Boundary::Publish, index)?;
                    writer.publish(dest)?;
                    self.published.set(self.published.get() + 1);
                    self.boundary(Boundary::Published, index)?;
                    let snapshot = self.verify_output(index, dest, identity, &expected)?;
                    self.check(index)?;
                    drop(writer);
                    Value::Checked(proof, snapshot)
                }
                _ => return Err("Invalid skill input".into()),
            };
        }
        match value {
            Value::Checked(proof, _) => Ok(proof),
            _ => Err("Incomplete composition".into()),
        }
    }
    fn create(&self, index: usize, expected: &str) -> Result<(Staging, (u32, u32, u32))> {
        let path = self
            .output
            .with_file_name(format!(".reflex-{}.tmp", task_integrity::run_id()));
        self.boundary(Boundary::StageCreate, index)?;
        let file = OpenOptions::new()
            .access_mode(0xC0010000) // Generic read/write plus DELETE for handle-based rename.
            .write(true)
            .read(true)
            .create_new(true)
            .share_mode(1)
            .open(&path)
            .map_err(|_| "Exclusive derived creation failed")?;
        let mut writer = Staging {
            file,
            path,
            published: false,
        };
        let identity = saved_text::file_identity(&writer.file)?;
        self.check(index)?;
        for chunk in expected.as_bytes().chunks(1024) {
            self.check(index)?;
            writer
                .file
                .write_all(chunk)
                .map_err(|_| "Derived write uncertain")?;
            self.boundary(Boundary::StageWrite, index)?;
        }
        self.boundary(Boundary::Sync, index)?;
        writer
            .file
            .sync_all()
            .map_err(|_| "Derived sync uncertain")?;
        Ok((writer, identity))
    }
    fn verify_output(
        &self,
        index: usize,
        path: &Path,
        identity: (u32, u32, u32),
        expected: &str,
    ) -> Result<String> {
        let reader =
            local_files::open(path, true, 7).map_err(|_| "Derived readback unavailable")?;
        self.boundary(Boundary::Readback, index)?;
        let mut observed = Vec::new();
        if saved_text::file_identity(&reader)? != identity {
            return Err("Derived identity changed".into());
        }
        reader
            .take(8193)
            .read_to_end(&mut observed)
            .map_err(|_| "Derived readback failed")?;
        if observed != expected.as_bytes() {
            return Err("Derived contents differ".into());
        }
        Ok(String::from_utf8(observed).map_err(|_| "Invalid derived encoding")?)
    }
}
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct Claim {
    task: String,
    attempt: String,
    digest: String,
}
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    version: u8,
    goal: String,
    editor: String,
    destination: String,
    suffix: String,
    second_destination: Option<String>,
    second_suffix: Option<String>,
}
fn private_bytes(path: &Path, limit: u64) -> Result<Vec<u8>> {
    let file =
        local_files::open_for_readback(path).map_err(|_| "Private authorization unavailable")?;
    let mut bytes = Vec::new();
    file.take(limit + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        return Err("Oversized authorization".into());
    }
    Ok(bytes)
}
pub(crate) fn claimed() -> Result<()> {
    use sha2::{Digest, Sha256};
    let id = task_integrity::task_id().ok_or("Missing queue task")?;
    let root = std::env::current_dir()?;
    let running = root.join("data/bridge/running");
    let manifest = private_bytes(&running.join(format!("{id}.job")), 256)?;
    if std::str::from_utf8(&manifest)?.lines().collect::<Vec<_>>() != ["REVIEW", "compose-text.ps1"]
    {
        return Err("Invalid claim manifest".into());
    }
    let claim: Claim = serde_json::from_slice(&private_bytes(
        &running.join(format!("{id}.claim.json")),
        1024,
    )?)?;
    let bytes = private_bytes(&root.join(format!("data/private/handoff/{id}.json")), 24576)?;
    let digest = format!(
        "{:x}",
        Sha256::new()
            .chain_update(id.as_bytes())
            .chain_update(b"\n")
            .chain_update(&bytes)
            .finalize()
    );
    if claim.task != id
        || claim.digest != digest
        || private_bytes(
            &root.join(format!("data/bridge/queue-requests/{id}.approve")),
            64,
        )? != digest.as_bytes()
    {
        return Err("Request differs from approval".into());
    }
    let r: Request = serde_json::from_slice(&bytes)?;
    let length = if r.editor == "notepad" { 32 } else { 56 };
    if claim.attempt.len() != length
        || !claim
            .attempt
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        || r.version != 1
    {
        return Err("Incompatible attempt".into());
    }
    let mut args = vec![r.editor, r.destination, r.suffix];
    match (r.goal.as_str(), r.second_destination, r.second_suffix) {
        ("editor.derive_copy", None, None) => {}
        ("editor.derive_chain", Some(p), Some(s)) => args.extend(["--then".into(), p, s]),
        _ => return Err("Invalid approved graph".into()),
    }
    args.extend(["--create", "--verify", "--consume", "--derive", "--publish"].map(str::to_owned));
    task_integrity::check_cancel()?;
    let _spent = OpenOptions::new()
        .create_new(true)
        .write(true)
        .share_mode(0)
        .open(running.join(format!("{id}.spent")))
        .map_err(|_| "Attempt already consumed")?;
    execute(&args, Some(&claim))
}
pub(crate) fn run(args: &[String]) -> Result<()> {
    if std::env::var_os("REFLEXCORE_QUEUE_MANIFEST").is_some() {
        return Err("Direct operator approval required".into());
    }
    execute(args, None)
}
fn execute(args: &[String], claim: Option<&Claim>) -> Result<()> {
    let [app, output, suffix, flags @ ..] = args else {
        return Err("Expected editor, output, suffix and permissions".into());
    };
    let (adapter, background) = match app.as_str() {
        "notepad" => (Adapter::Notepad, false),
        "winforms" => (Adapter::Winforms, false),
        "winforms-background" => (Adapter::Winforms, true),
        _ => return Err("Unsupported editor".into()),
    };
    let (second, flags) = match flags {
        [then, path, value, rest @ ..] if then == "--then" => {
            (Some((Path::new(path), value)), rest)
        }
        _ => (None, flags),
    };
    let graph: &[Step] = if second.is_some() { &CHAIN } else { &GRAPH };
    let mut grants = 0;
    for flag in flags {
        grants |= match flag.as_str() {
            "--create" => CREATE,
            "--verify" => READ,
            "--consume" => CONSUME,
            "--derive" => DERIVE,
            "--publish" => PUBLISH,
            _ => return Err("Unknown permission".into()),
        };
    }
    preflight(graph, grants)?;
    let binding = saved_text::bind(saved_text::ID, 1, adapter, background)?;
    if suffix.is_empty() || suffix.len() > 4096 {
        return Err("Invalid suffix size".into());
    }
    let (scope, output) =
        local_files::target(Path::new(output)).map_err(|_| "Unsupported output scope")?;
    if output.try_exists().map_err(|_| "Output unavailable")? {
        return Err("Output already exists".into());
    }
    scope.require_ntfs()?;
    let second = if let Some((path, value)) = second {
        let (_pin, path) = local_files::target(path).map_err(|_| "Invalid second destination")?;
        if value.is_empty()
            || value.len() + suffix.len() > 4096
            || path.parent() != output.parent()
            || path.try_exists()?
            || path.to_string_lossy().to_uppercase() == output.to_string_lossy().to_uppercase()
        {
            return Err("Invalid second destination or budget".into());
        }
        Some((path, value.clone()))
    } else {
        None
    };
    let plan = Plan {
        progress: claim.map(|c| {
            (
                PathBuf::from(format!("data/bridge/running/{}.progress", c.task)),
                c.attempt.clone(),
            )
        }),
        graph,
        second,
        stop_path: "data/bridge/global-stop.signal".into(),
        published: 0.into(),
        #[cfg(test)]
        probe: None,
        binding,
        adapter,
        grants,
        started: std::time::SystemTime::now(),
        deadline: Instant::now() + Duration::from_secs(60),
        _scope: scope,
        output,
        suffix: suffix.clone(),
    };
    let mut run = claim
        .map(|c| c.attempt.clone())
        .unwrap_or_else(task_integrity::run_id);
    let execution = (|| -> Result<()> {
        plan.boundary(Boundary::Launch, 0)?;
        plan.progress(0)?;
        if adapter == Adapter::Winforms {
            crate::flow::verified_demo(background, &run, Some(&plan))?;
        } else {
            // Keep the counter and PID from the run nonce.
            if claim.is_none() {
                run = run[24..].to_owned();
            }
            let ps = std::env::var_os("SystemRoot").ok_or("Windows unavailable")?;
            let mut worker = Command::new(
                PathBuf::from(ps).join("System32/WindowsPowerShell/v1.0/powershell.exe"),
            )
            .args([
                "-NoProfile",
                "-File",
                "tools/ReflexCore-VisionLoop.ps1",
                "-Action",
                "DemoNotepad",
                "-TestFixture",
                "-AllowInput",
                "-UnicodeFixture",
                "-CompositionRun",
                &run,
            ])
            .stdout(Stdio::null())
            .spawn()
            .map_err(|_| "Editor startup failed")?;
            loop {
                if let Err(e) = plan.check(0) {
                    let _ = worker.kill();
                    let _ = worker.wait();
                    return Err(e);
                }
                if let Some(status) = worker.try_wait()? {
                    if !status.success() {
                        return Err("Editor failed".into());
                    }
                    break;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            plan.finish(&run, "ReflexCore ЖΩ😀")?;
        }
        plan.boundary(Boundary::Terminal, graph.len() - 1)
    })();
    if let Some(c) = claim {
        let cancelled = execution
            .as_ref()
            .err()
            .and_then(|e| e.downcast_ref::<task_integrity::Fault>())
            .is_some_and(|f| {
                matches!(
                    f,
                    task_integrity::Fault::Cancelled | task_integrity::Fault::CancelledUnknown
                )
            });
        let outcome = if execution.is_ok() {
            "verified"
        } else if cancelled {
            "cancelled"
        } else {
            "failed"
        };
        let record = serde_json::json!({"schema":"reflexcore.task.receipt.v1","task_id":c.task,"run_id":c.attempt,
            "stage":"composition","goal":if plan.second.is_some(){"editor.derive_chain"}else{"editor.derive_copy"},
            "version":1,"editor":app,"outcome":outcome,"verification":if execution.is_ok(){"verified"}else{"unknown"},
            "reason":if execution.is_ok(){"verified_goal"}else if cancelled{"cancelled_effect_unknown"}else{"process_failed"},
            "completed_steps":if execution.is_ok(){Some(graph.len())}else{None},"published_outputs":plan.published.get()});
        task_integrity::publish_receipt(&c.task, &c.attempt, &record)?;
    }
    if let Err(error) = execution {
        let cancelled = matches!(
            error.downcast_ref::<task_integrity::Fault>(),
            Some(task_integrity::Fault::Cancelled | task_integrity::Fault::CancelledUnknown)
        );
        println!(
            "{}",
            serde_json::json!({"schema":"reflexcore.composed_goal.v1","run_id":run,"goal":if plan.second.is_some(){"editor.derive_chain"}else{"editor.derive_copy"},"version":1,"adapter":adapter,"outcome":if cancelled{"cancelled"}else{"failed"},"published_outputs":plan.published.get(),"derived_effect":if plan.published.get()>0{"published"}else{"not_published"}})
        );
        return Err(error);
    }
    println!(
        "{}",
        serde_json::json!({"schema":"reflexcore.composed_goal.v1","goal":if plan.second.is_some(){"editor.derive_chain"}else{"editor.derive_copy"},"version":1,"run_id":run,"adapter":adapter,"outcome":"verified","published_outputs":plan.published.get(),"steps":graph.iter().map(|s|(s.id,s.version)).collect::<Vec<_>>() })
    );
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    #[ignore = "paired filesystem timing on a local NTFS volume"]
    fn paired_copy_timing() {
        let mut times = [Vec::new(), Vec::new()];
        for pair in 0..32 {
            for arm in [pair % 2, 1 - pair % 2] {
                let run = task_integrity::run_id();
                let root = saved_text::winforms_folder(&run).unwrap();
                std::fs::create_dir(&root).unwrap();
                std::fs::write(root.join("saved.txt"), "source").unwrap();
                let (scope, output) = local_files::target(&root.join("result.txt")).unwrap();
                let plan = Plan {
                    progress: None, graph: &GRAPH, second: None, stop_path: root.join("stop"),
                    published: 0.into(), probe: None,
                    binding: saved_text::bind(saved_text::ID, 1, Adapter::Winforms, true).unwrap(),
                    adapter: Adapter::Winforms, grants: 31, deadline: Instant::now() + Duration::from_secs(30),
                    started: std::time::SystemTime::now(), _scope: scope, output, suffix: "!".into(),
                };
                let start = Instant::now();
                if arm == 1 {
                    plan.finish(&run, "source").unwrap();
                } else {
                    plan.check(1).unwrap();
                    let artifact = plan.binding.artifact(&run, "source").unwrap();
                    plan.check(2).unwrap();
                    plan.boundary(Boundary::SourceVerified, 2).unwrap();
                    let (_proof, bytes) = artifact.consume(&run, plan.adapter).unwrap();
                    assert!(plan.binding.matches_snapshot(&bytes, "source"));
                    let expected = format!("source{}", plan.suffix);
                    plan.check(2).unwrap();
                    let (mut stage, id) = plan.create(2, &expected).unwrap();
                    plan.check(3).unwrap();
                    plan.verify_output(3, &stage.path, id, &expected).unwrap();
                    plan.boundary(Boundary::Publish, 3).unwrap();
                    stage.publish(&plan.output).unwrap();
                    plan.published.set(1);
                    plan.boundary(Boundary::Published, 3).unwrap();
                    plan.verify_output(3, &plan.output, id, &expected).unwrap();
                    plan.check(3).unwrap();
                }
                let us = start.elapsed().as_micros();
                assert_eq!(std::fs::read(&plan.output).unwrap(), b"source!");
                if pair >= 2 { times[arm].push(us); }
                drop(plan);
                for name in ["saved.txt", "result.txt"] { std::fs::remove_file(root.join(name)).unwrap(); }
                std::fs::remove_dir(root).unwrap();
            }
        }
        for (arm, values) in times.iter_mut().enumerate() {
            values.sort_unstable();
            println!("arm={arm} n=30 p50_us={} p95_us={} p99_max_us={}", values[14], values[28], values[29]);
        }
    }
    #[test]
    fn abrupt_composition_exit() {
        use Boundary::*;
        const NAME: &str = "skill_registry::composition::tests::abrupt_composition_exit";
        if let Ok(run) = std::env::var("REFLEX_TEST_CRASH_RUN") {
            let root = saved_text::winforms_folder(&run).unwrap();
            let (scope, output) = local_files::target(&root.join("first.txt")).unwrap();
            let boundary = std::env::var("REFLEX_TEST_CRASH_BOUNDARY").unwrap();
            let seen = std::cell::Cell::new(0);
            let second = root.join("second.txt");
            let plan = Plan {
                progress: None,
                graph: &CHAIN,
                second: Some((second, "B".into())),
                stop_path: root.join("stop"),
                published: 0.into(),
                probe: Some(Box::new(move |stage| {
                    if format!("{stage:?}") == boundary
                        || (stage == Publish && boundary == "SecondPublish" && seen.get() == 1)
                    {
                        std::process::exit(73);
                    }
                    if stage == Publish {
                        seen.set(seen.get() + 1);
                    }
                })),
                binding: saved_text::bind(saved_text::ID, 1, Adapter::Winforms, true).unwrap(),
                adapter: Adapter::Winforms,
                grants: 31,
                deadline: Instant::now() + Duration::from_secs(60),
                started: std::time::SystemTime::now(),
                _scope: scope,
                output,
                suffix: "A".into(),
            };
            plan.boundary(Launch, 0).unwrap();
            plan.check_editor().unwrap();
            std::fs::write(root.join("saved.txt"), "source").unwrap();
            plan.finish(&run, "source").unwrap();
            plan.boundary(Terminal, 5).unwrap();
            return;
        }
        for (stage, count) in [
            ("Launch", 0),
            ("EditorAction", 0),
            ("SourceVerified", 0),
            ("StageWrite", 0),
            ("Published", 1),
            ("SecondPublish", 1),
            ("Terminal", 2),
            ("Recovery", 2),
        ] {
            let run = task_integrity::run_id();
            let root = saved_text::winforms_folder(&run).unwrap();
            std::fs::create_dir(&root).unwrap();
            let status = Command::new(std::env::current_exe().unwrap())
                .args(["--exact", NAME])
                .env("REFLEX_TEST_CRASH_RUN", &run)
                .env("REFLEX_TEST_CRASH_BOUNDARY", stage)
                .stdout(Stdio::null())
                .status()
                .unwrap();
            assert_eq!(
                status.code(),
                Some(if stage == "Recovery" { 0 } else { 73 })
            );
            for (index, (name, expected)) in [("first.txt", "sourceA"), ("second.txt", "sourceAB")]
                .iter()
                .enumerate()
            {
                let p = root.join(name);
                assert_eq!(p.exists(), index < count);
                if p.exists() {
                    assert_eq!(std::fs::read_to_string(p).unwrap(), *expected);
                }
            }
            // This uniquely created directory contains only this test's fixtures.
            std::fs::remove_dir_all(root).unwrap();
        }
    }
    #[test]
    fn stop_at_each_boundary_preserves_actual_effects() {
        use Boundary::*;
        for at in [
            Launch,
            EditorAction,
            SourceVerified,
            StageCreate,
            StageWrite,
            Sync,
            Readback,
            Publish,
            Published,
            Terminal,
        ] {
            let run = task_integrity::run_id();
            let root = saved_text::winforms_folder(&run).unwrap();
            std::fs::create_dir(&root).unwrap();
            let output = root.join("result.txt");
            let stop = root.join("stop");
            let (scope, path) = local_files::target(&output).unwrap();
            let marker = stop.clone();
            let plan = Plan {
                progress: None,
                graph: &GRAPH,
                second: None,
                stop_path: stop.clone(),
                published: 0.into(),
                probe: Some(Box::new(move |stage| {
                    if stage == at {
                        std::thread::scope(|s| {
                            s.spawn(|| std::fs::write(&marker, b"stop"))
                                .join()
                                .unwrap()
                                .unwrap()
                        });
                    }
                })),
                binding: saved_text::bind(saved_text::ID, 1, Adapter::Winforms, true).unwrap(),
                adapter: Adapter::Winforms,
                grants: 31,
                deadline: Instant::now() + Duration::from_secs(30),
                started: std::time::UNIX_EPOCH,
                _scope: scope,
                output: path,
                suffix: "!".repeat(2048),
            };
            let original = root.join("saved.txt");
            let result = (|| -> Result<()> {
                plan.boundary(Launch, 0)?;
                plan.check_editor()?;
                std::fs::write(&original, "source")?;
                plan.finish(&run, "source")?;
                plan.boundary(Terminal, 3)
            })();
            assert!(matches!(
                result.unwrap_err().downcast_ref::<task_integrity::Fault>(),
                Some(task_integrity::Fault::Cancelled)
            ));
            assert_eq!(original.exists(), !matches!(at, Launch | EditorAction));
            assert_eq!(output.exists(), matches!(at, Published | Terminal));
            assert_eq!(output.exists(), plan.published.get() > 0);
            drop(plan);
            if output.exists() {
                assert_eq!(
                    std::fs::read_to_string(&output).unwrap(),
                    format!("source{}", "!".repeat(2048))
                );
                std::fs::remove_file(output).unwrap();
            }
            if original.exists() {
                assert_eq!(std::fs::read(&original).unwrap(), b"source");
                std::fs::remove_file(original).unwrap();
            }
            std::fs::remove_file(stop).unwrap();
            std::fs::remove_dir(root).unwrap();
        }
    }
    #[test]
    fn competing_destination_and_recovery() {
        let root =
            std::env::temp_dir().join(format!("reflex-compose-{}", task_integrity::run_id()));
        std::fs::create_dir(&root).unwrap();
        let output = root.join("result.txt");
        let (scope, path) = local_files::target(&output).unwrap();
        let mut plan = Plan {
            progress: None,
            graph: &GRAPH,
            second: None,
            stop_path: root.join("stop"),
            published: 0.into(),
            probe: None,
            binding: saved_text::bind(saved_text::ID, 1, Adapter::Winforms, true).unwrap(),
            adapter: Adapter::Winforms,
            grants: 31,
            started: std::time::SystemTime::now(),
            deadline: Instant::now() + Duration::from_secs(30),
            _scope: scope,
            output: path,
            suffix: "!".into(),
        };
        let (mut stage, id) = plan.create(2, "verified").unwrap();
        assert!(plan.verify_output(3, &stage.path, id, "wrong").is_err());
        // The competitor wins the destination name after staging, before rename.
        std::thread::scope(|s| {
            s.spawn(|| std::fs::write(&output, "winner"))
                .join()
                .unwrap()
                .unwrap()
        });
        assert!(stage.publish(&output).is_err());
        let staging_name = stage.path.clone();
        drop(stage);
        assert!(!staging_name.exists());
        assert_eq!(std::fs::read_to_string(&output).unwrap(), "winner");
        std::fs::remove_file(&output).unwrap();
        let (mut fresh, id) = plan.create(2, "verified").unwrap();
        fresh.publish(&output).unwrap();
        assert!(std::fs::rename(&output, root.join("substitute")).is_err());
        plan.verify_output(3, &output, id, "verified").unwrap();
        plan.deadline = Instant::now();
        assert!(plan.check(3).is_err());
        drop(fresh);
        assert_eq!(std::fs::read_to_string(&output).unwrap(), "verified");
        drop(plan);
        std::fs::remove_file(output).unwrap();
        std::fs::remove_dir(root).unwrap();
    }
    #[test]
    fn graph_rejects_missing_authority_and_invalid_edges() {
        for bit in [CREATE, READ, CONSUME, DERIVE, PUBLISH] {
            assert!(preflight(&GRAPH, 31 ^ bit).is_err())
        }
        assert!(preflight(&GRAPH, 31).is_ok());
        let mut g = GRAPH;
        g[2].from = Some(2);
        assert!(preflight(&g, 31).is_err());
        let mut g = GRAPH;
        g[3].from = Some(1);
        assert!(preflight(&g, 31).is_err());
        let mut g = GRAPH;
        g[1].version = 2;
        assert!(preflight(&g, 31).is_err());
    }
}
