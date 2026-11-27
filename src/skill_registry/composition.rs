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
fn preflight(graph: &[Step], grants: u8) -> Result<()> {
    if graph.len() != GRAPH.len() {
        return Err("Unsupported composition size".into());
    }
    for (i, (s, registered)) in graph.iter().zip(&GRAPH).enumerate() {
        if s.id != registered.id
            || s.version != registered.version
            || s.output != registered.output
            || s.input != registered.input
            || s.permissions != registered.permissions
            || grants & s.permissions != s.permissions
            || s.from != registered.from
            || s.from
                .is_some_and(|j| j >= i || Some(graph[j].output) != s.input)
        {
            return Err("Incompatible or unauthorized skill edge".into());
        }
    }
    Ok(())
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
pub(crate) struct Plan {
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
    fn check(&self, index: usize) -> Result<()> {
        task_integrity::check_cancel()?;
        match std::fs::metadata("data/bridge/global-stop.signal") {
            Ok(meta) if meta.modified()? >= self.started => {
                return Err(task_integrity::Fault::Cancelled.into())
            }
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => {
                return Err("Stop state unavailable".into())
            }
            _ => {}
        }
        if Instant::now() >= self.deadline
            || self.grants & GRAPH[index].permissions != GRAPH[index].permissions
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
            Checked(Evidence<'a>),
        }
        let mut value = Value::Document;
        for (index, step) in GRAPH.iter().enumerate().skip(1) {
            self.check(index)?;
            value = match (step.output, value) {
                (Port::LiveText, Value::Document) => Value::Live(self.binding.artifact(run, text)?),
                (Port::Derived, Value::Live(source)) => {
                    let (proof, snapshot) = source.consume(run, self.adapter)?;
                    if !self.binding.matches_snapshot(&snapshot, text) {
                        return Err("Snapshot invalidated".into());
                    }
                    let expected = [text, self.suffix.as_str()].concat();
                    self.check(index)?;
                    let (writer, identity) = self.create(&expected)?;
                    Value::Derived(proof, writer, identity, expected)
                }
                (Port::Checked, Value::Derived(proof, mut writer, identity, expected)) => {
                    self.verify_output(&writer.path, identity, &expected)?;
                    self.check(index)?;
                    writer.publish(&self.output)?;
                    self.verify_output(&self.output, identity, &expected)?;
                    self.check(index)?;
                    drop(writer);
                    Value::Checked(proof)
                }
                _ => return Err("Invalid skill input".into()),
            };
        }
        match value {
            Value::Checked(proof) => Ok(proof),
            _ => Err("Incomplete composition".into()),
        }
    }
    fn create(&self, expected: &str) -> Result<(Staging, (u32, u32, u32))> {
        let path = self
            .output
            .with_file_name(format!(".reflex-{}.tmp", task_integrity::run_id()));
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
        self.check(2)?;
        writer
            .file
            .write_all(expected.as_bytes())
            .and_then(|_| writer.file.sync_all())
            .map_err(|_| "Derived write uncertain")?;
        Ok((writer, identity))
    }
    fn verify_output(&self, path: &Path, identity: (u32, u32, u32), expected: &str) -> Result<()> {
        let reader =
            local_files::open(path, true, 7).map_err(|_| "Derived readback unavailable")?;
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
        Ok(())
    }
}
pub(crate) fn run(args: &[String]) -> Result<()> {
    let [app, output, suffix, flags @ ..] = args else {
        return Err("Expected editor, absolute output, suffix and permission flags".into());
    };
    if task_integrity::task_id().is_some()
        || std::env::var_os("REFLEXCORE_QUEUE_MANIFEST").is_some()
    {
        return Err("Direct operator approval required".into());
    }
    let (adapter, background) = match app.as_str() {
        "notepad" => (Adapter::Notepad, false),
        "winforms" => (Adapter::Winforms, false),
        "winforms-background" => (Adapter::Winforms, true),
        _ => return Err("Unsupported editor".into()),
    };
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
    preflight(&GRAPH, grants)?;
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
    let plan = Plan {
        binding,
        adapter,
        grants,
        started: std::time::SystemTime::now(),
        deadline: Instant::now() + Duration::from_secs(60),
        _scope: scope,
        output,
        suffix: suffix.clone(),
    };
    let mut run = task_integrity::run_id();
    plan.check(0)?;
    if adapter == Adapter::Winforms {
        crate::flow::verified_demo(background, &run, Some(&plan))?;
    } else {
        // Keep the counter and PID from the run nonce.
        run = run[24..].to_owned();
        let ps = std::env::var_os("SystemRoot").ok_or("Windows unavailable")?;
        let mut worker =
            Command::new(PathBuf::from(ps).join("System32/WindowsPowerShell/v1.0/powershell.exe"))
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
    plan.check(3)?;
    println!(
        "{}",
        serde_json::json!({"schema":"reflexcore.composed_goal.v1","goal":"editor.derive_copy","version":1,"run_id":run,"adapter":adapter,"outcome":"verified","steps":GRAPH.iter().map(|s|(s.id,s.version)).collect::<Vec<_>>() })
    );
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn competing_destination_and_recovery() {
        let root =
            std::env::temp_dir().join(format!("reflex-compose-{}", task_integrity::run_id()));
        std::fs::create_dir(&root).unwrap();
        let output = root.join("result.txt");
        let (scope, path) = local_files::target(&output).unwrap();
        let mut plan = Plan {
            binding: saved_text::bind(saved_text::ID, 1, Adapter::Winforms, true).unwrap(),
            adapter: Adapter::Winforms,
            grants: 31,
            started: std::time::SystemTime::now(),
            deadline: Instant::now() + Duration::from_secs(30),
            _scope: scope,
            output: path,
            suffix: "!".into(),
        };
        let (mut stage, id) = plan.create("verified").unwrap();
        assert!(plan.verify_output(&stage.path, id, "wrong").is_err());
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
        let (mut fresh, id) = plan.create("verified").unwrap();
        fresh.publish(&output).unwrap();
        assert!(std::fs::rename(&output, root.join("substitute")).is_err());
        plan.verify_output(&output, id, "verified").unwrap();
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
