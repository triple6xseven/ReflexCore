use super::{clock_us, metrics, Result};
use crate::task_integrity::{self, Fault};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    io::{Read, Write},
    os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle},
    os::windows::process::CommandExt,
    process::{Child, Command, Stdio},
    sync::mpsc::{self, Receiver, SyncSender},
    thread::{self, JoinHandle},
    time::Duration,
};
use windows::Win32::System::Threading::CREATE_NO_WINDOW;

const LIMIT: usize = 262144;
const VERSION: u8 = 1;

fn contain(worker: &Child) -> Result<OwnedHandle> {
    use windows::Win32::Foundation::HANDLE;
    use windows::Win32::System::JobObjects::*;
    // The kernel closes this non-inheritable handle even on supervisor crash.
    let job = unsafe { CreateJobObjectW(None, None)? };
    let owned = unsafe { OwnedHandle::from_raw_handle(job.0) };
    let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    unsafe {
        SetInformationJobObject(
            job,
            JobObjectExtendedLimitInformation,
            (&limits as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
            std::mem::size_of_val(&limits) as u32,
        )?;
        AssignProcessToJobObject(job, HANDLE(worker.as_raw_handle()))?;
    }
    Ok(owned)
}

#[derive(Serialize, Deserialize, PartialEq, Eq, Clone)]
#[serde(deny_unknown_fields)]
struct Header {
    version: u8,
    session: String,
    run: String,
    action: usize,
    hwnd: usize,
    pid: u32,
    deadline_us: u64,
    capability: String,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    header: Header,
    payload: WireAction,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct WireAction {
    action: String,
    name: String,
    automation_id: Option<String>,
    path: Option<String>,
    kind: Option<String>,
    value: Option<String>,
    execute: bool,
    timeout_ms: u64,
    max_nodes: usize,
    fixture_owner: u32,
    require_foreground: bool,
}

impl WireAction {
    fn allowed(&self) -> bool {
        (100..=300_000).contains(&self.timeout_ms)
            && self.automation_id.is_none()
            && self.path.is_none()
            && self.kind.is_none()
            && match self.action.as_str() {
                "assert-value" => !self.execute && self.value.is_some(),
                "set-value" => self.execute && self.value.is_some(),
                "invoke" => self.execute && self.value.is_none(),
                _ => false,
            }
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Reply {
    header: Header,
    result: std::result::Result<Value, WorkerError>,
}

#[derive(Serialize, Deserialize)]
enum WorkerError {
    Cancelled,
    Expired,
    LostIdentity,
    Provider,
}

fn frame<T: Serialize>(out: &mut impl Write, value: &T) -> Result<()> {
    let bytes = serde_json::to_vec(value)?;
    if bytes.len() > LIMIT {
        return Err("Oversized session frame".into());
    }
    out.write_all(&(bytes.len() as u32).to_le_bytes())?;
    out.write_all(&bytes)?;
    out.flush()?;
    Ok(())
}

fn receive<T: DeserializeOwned>(input: &mut impl Read) -> Result<T> {
    let mut size = [0; 4];
    input.read_exact(&mut size)?;
    let len = u32::from_le_bytes(size) as usize;
    if len == 0 || len > LIMIT {
        return Err("Invalid session frame length".into());
    }
    let mut bytes = vec![0; len];
    input.read_exact(&mut bytes)?;
    Ok(serde_json::from_slice(&bytes)?)
}

pub(crate) struct Session {
    _job: OwnedHandle,
    child: Child,
    sender: Option<SyncSender<Request>>,
    receiver: Receiver<(Reply, u64)>,
    pump: Option<JoinHandle<()>>,
    header: Header,
    spawn_start: u64,
    spawn_us: u64,
}

impl Session {
    pub(crate) fn close(self) -> u128 {
        let start = std::time::Instant::now();
        drop(self);
        start.elapsed().as_micros()
    }

    pub(crate) fn start(run: &str, hwnd: usize, pid: u32) -> Result<Self> {
        task_integrity::check_cancel()?;
        let id = task_integrity::run_id();
        let spawn_start = clock_us();
        let mut child = Command::new(std::env::current_exe()?)
            .creation_flags(CREATE_NO_WINDOW.0)
            .args([
                "uia-session-worker",
                &id,
                run,
                &hwnd.to_string(),
                &pid.to_string(),
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let spawn_us = clock_us() - spawn_start;
        let job = match contain(&child) {
            Ok(job) => job,
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(error);
            }
        };
        let mut stdin = child.stdin.take().unwrap();
        let mut stdout = child.stdout.take().unwrap();
        let (sender, next) = mpsc::sync_channel::<Request>(1);
        let (done, receiver) = mpsc::sync_channel(1);
        // A blocked pipe write or read cannot hold the supervisor past its deadline.
        let pump = thread::Builder::new()
            .name("uia-session-io".into())
            .spawn(move || {
                while let Ok(request) = next.recv() {
                    if frame(&mut stdin, &request).is_err() {
                        break;
                    }
                    let Ok(reply) = receive(&mut stdout) else {
                        break;
                    };
                    let mut stamp = [0; 8];
                    if stdout.read_exact(&mut stamp).is_err() {
                        break;
                    }
                    if done.send((reply, u64::from_le_bytes(stamp))).is_err() {
                        break;
                    }
                }
            });
        let pump = match pump {
            Ok(pump) => pump,
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(error.into());
            }
        };
        let header = Header {
            version: VERSION,
            session: id,
            run: run.into(),
            action: 0,
            hwnd,
            pid,
            deadline_us: 0,
            capability: String::new(),
        };
        Ok(Self {
            _job: job,
            child,
            sender: Some(sender),
            receiver,
            pump: Some(pump),
            header,
            spawn_start,
            spawn_us,
        })
    }

    pub(super) fn dispatch(
        &mut self,
        hwnd: usize,
        owner: Option<u32>,
        action: usize,
        wire: Value,
    ) -> Result<Value> {
        if hwnd != self.header.hwnd
            || owner != Some(self.header.pid)
            || action != self.header.action + 1
        {
            return Err(Fault::PreconditionFailed.into());
        }
        task_integrity::check_cancel()?;
        self.header.action = action;
        self.header.capability = wire["action"].as_str().ok_or("Missing capability")?.into();
        self.header.deadline_us =
            clock_us() + (wire["timeout_ms"].as_u64().ok_or("Missing deadline")? + 1500) * 1000;
        let payload: WireAction = serde_json::from_value(wire)?;
        if !payload.allowed() {
            return Err(Fault::PreconditionFailed.into());
        }
        self.sender
            .as_ref()
            .ok_or(Fault::Infrastructure)?
            .try_send(Request {
                header: self.header.clone(),
                payload,
            })
            .map_err(|_| Fault::Infrastructure)?;
        let mut peak = None;
        let (reply, published) = loop {
            if task_integrity::cancelled() {
                return Err(Fault::CancelledUnknown.into());
            }
            let remaining = self.header.deadline_us.saturating_sub(clock_us());
            if remaining == 0 {
                return Err(Fault::EffectUnknown.into());
            }
            metrics::sample_pair(&self.child, &mut peak);
            match self
                .receiver
                .recv_timeout(Duration::from_micros(remaining.min(25_000)))
            {
                Ok(reply) => break reply,
                Err(mpsc::RecvTimeoutError::Timeout) => continue,
                Err(_) => return Err(Fault::EffectUnknown.into()),
            }
        };
        let received = clock_us();
        task_integrity::check_cancel().map_err(|_| Fault::CancelledUnknown)?;
        if received >= self.header.deadline_us || reply.header != self.header {
            return Err(Fault::EffectUnknown.into());
        }
        let mut value = reply.result.map_err(|error| match error {
            WorkerError::LostIdentity => Fault::FocusLost,
            WorkerError::Cancelled => Fault::CancelledUnknown,
            _ => Fault::EffectUnknown,
        })?;
        if value["schema"] != "reflexcore.uia.action.v1"
            || !valid_phases(&value["phases"])
            || !valid_result(&value, &self.header.capability)
        {
            return Err(Fault::EffectUnknown.into());
        }
        let m = &mut value["phases"];
        m["response_write_us"] = json!(m["publishing_us"]
            .as_u64()
            .map(|v| published.saturating_sub(v)));
        m["ack_us"] = json!(received.saturating_sub(published));
        m["validate_us"] = json!(clock_us() - received);
        m["reply_transport_us"] = json!(m["publishing_us"]
            .as_u64()
            .map(|v| received.saturating_sub(v)));
        m["spawn_us"] = json!(if action == 1 { self.spawn_us } else { 0 });
        m["startup_from_spawn_us"] = json!(if action == 1 {
            m["entry_us"]
                .as_u64()
                .map(|v| v.saturating_sub(self.spawn_start))
        } else {
            None
        });
        m["concurrent_private_bytes"] = json!(peak);
        m["root_private_bytes"] = json!(metrics::private_bytes());
        m["root_cpu_us"] = json!(metrics::cpu_us());
        m["action_id"] = json!(action);
        Ok(value)
    }
}

fn valid_phases(value: &Value) -> bool {
    let Some(fields) = value.as_object() else {
        return false;
    };
    let required = [
        "entry_us",
        "com_us",
        "uia_us",
        "discovery_us",
        "operation_us",
        "publishing_us",
    ];
    required.iter().all(|key| value[*key].is_u64())
        && fields.iter().all(|(key, v)| {
            required.contains(&key.as_str())
                || (matches!(
                    key.as_str(),
                    "verification_us" | "child_private_bytes" | "child_cpu_us"
                ) && (v.is_null() || v.is_u64()))
        })
}

fn valid_result(value: &Value, capability: &str) -> bool {
    match (value["status"].as_str(), value["verification"].as_str()) {
        (Some("issued"), Some("verified")) => capability == "set-value",
        (Some("issued"), Some("not_verified")) => matches!(capability, "set-value" | "invoke"),
        (Some("assertion_passed"), Some("verified"))
        | (Some("assertion_failed"), Some("failed"))
        | (Some("assertion_error"), Some("unknown")) => capability == "assert-value",
        (
            Some(
                "scan_incomplete" | "not_found" | "ambiguous" | "cancelled" | "focus_lost"
                | "action_error",
            ),
            Some("not_applicable"),
        ) => true,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn losing_the_supervisor_job_terminates_its_worker() {
        use windows::Win32::{
            Foundation::{HANDLE, WAIT_OBJECT_0},
            System::Threading::WaitForSingleObject,
        };
        let mut child = Command::new("powershell.exe")
            .creation_flags(CREATE_NO_WINDOW.0)
            .args([
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                "Start-Sleep -Seconds 10",
            ])
            .spawn()
            .unwrap();
        let job = contain(&child).unwrap();
        assert!(child.try_wait().unwrap().is_none());
        drop(job);
        assert_eq!(
            unsafe { WaitForSingleObject(HANDLE(child.as_raw_handle()), 2000) },
            WAIT_OBJECT_0
        );
        child.wait().unwrap();
    }

    #[test]
    fn rejects_oversize_truncated_and_untyped_frames() {
        for data in [
            ((LIMIT + 1) as u32).to_le_bytes().to_vec(),
            vec![8, 0, 0, 0, b'{'],
            vec![2, 0, 0, 0, b'{', b'}'],
        ] {
            assert!(receive::<Reply>(&mut data.as_slice()).is_err());
        }
        assert!(!valid_result(
            &json!({"status":"issued","verification":"verified"}),
            "invoke"
        ));
        assert!(!valid_phases(&json!({"discovery_us":"private text"})));
    }

    #[test]
    fn supervisor_rejects_foreign_or_replayed_evidence() {
        for field in [
            "session",
            "run",
            "action",
            "hwnd",
            "pid",
            "capability",
            "deadline",
            "version",
        ] {
            let (sender, requests) = mpsc::sync_channel::<Request>(1);
            let (done, receiver) = mpsc::sync_channel(1);
            let pump = thread::spawn(move || {
                let mut header = requests.recv().unwrap().header;
                match field {
                    "session" => header.session.push('0'),
                    "run" => header.run.push('0'),
                    "action" => header.action -= 1,
                    "hwnd" => header.hwnd += 1,
                    "pid" => header.pid += 1,
                    "capability" => header.capability = "invoke".into(),
                    "deadline" => header.deadline_us += 1,
                    _ => header.version += 1,
                }
                let result = Ok(
                    json!({"schema":"reflexcore.uia.action.v1","status":"assertion_passed",
                    "verification":"verified","phases":{"entry_us":1,"com_us":0,"uia_us":0,
                    "discovery_us":1,"operation_us":1,"publishing_us":2}}),
                );
                done.send((Reply { header, result }, clock_us())).unwrap();
            });
            let header = Header {
                version: VERSION,
                session: task_integrity::run_id(),
                run: task_integrity::run_id(),
                action: 0,
                hwnd: 1,
                pid: 2,
                deadline_us: 0,
                capability: String::new(),
            };
            let child = Command::new("powershell.exe")
                .creation_flags(CREATE_NO_WINDOW.0)
                .args([
                    "-NoProfile",
                    "-NonInteractive",
                    "-Command",
                    "Start-Sleep -Seconds 10",
                ])
                .stdout(Stdio::null())
                .spawn()
                .unwrap();
            let job = contain(&child).unwrap();
            let mut session = Session {
                _job: job,
                child,
                header,
                sender: Some(sender),
                receiver,
                pump: Some(pump),
                spawn_start: clock_us(),
                spawn_us: 0,
            };
            let error = session
                .dispatch(
                    1,
                    Some(2),
                    1,
                    json!({"action":"assert-value","name":"Input","value":"expected","timeout_ms":500,
                        "max_nodes":0,"fixture_owner":2,"require_foreground":false,"execute":false}),
                )
                .unwrap_err();
            assert!(matches!(
                error.downcast_ref::<Fault>(),
                Some(Fault::EffectUnknown)
            ));
        }
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        drop(self.sender.take());
        let _ = self.child.kill();
        let _ = self.child.wait();
        if let Some(pump) = self.pump.take() {
            let _ = pump.join();
        }
    }
}

pub(crate) fn worker(args: &[String]) -> Result<()> {
    let entry = clock_us();
    let [id, run, hwnd, pid] = args else {
        return Err("Invalid session identity".into());
    };
    let hwnd: usize = hwnd.parse()?;
    let pid: u32 = pid.parse()?;
    let context = super::initialize()?;
    let mut stdin = std::io::stdin().lock();
    let mut stdout = std::io::stdout().lock();
    for action in 1..=512 {
        let request: Request = receive(&mut stdin)?;
        let h = &request.header;
        if h.version != VERSION
            || h.session != *id
            || h.run != *run
            || h.action != action
            || h.hwnd != hwnd
            || h.pid != pid
            || request.payload.fixture_owner != pid
            || request.payload.action != h.capability
            || !request.payload.allowed()
            || !matches!(
                h.capability.as_str(),
                "assert-value" | "set-value" | "invoke"
            )
        {
            return Err("Invalid session command".into());
        }
        let now = clock_us();
        let result = if task_integrity::cancelled() {
            Err(WorkerError::Cancelled)
        } else if now >= h.deadline_us || h.deadline_us - now > 301_500_000 {
            Err(WorkerError::Expired)
        } else if crate::observer::window_process(hwnd as *mut _) != pid {
            Err(WorkerError::LostIdentity)
        } else {
            let mut wire = serde_json::to_value(request.payload)?;
            wire["deadline_us"] = json!(h.deadline_us);
            let (start, com, uia) = if action == 1 {
                (entry, context.2, context.3)
            } else {
                (now, 0, 0)
            };
            super::perform(&context.0, hwnd, &wire, start, com, uia)
                .map_err(|_| WorkerError::Provider)
        };
        let terminal = result.is_err();
        frame(
            &mut stdout,
            &Reply {
                header: request.header,
                result,
            },
        )?;
        stdout.write_all(&clock_us().to_le_bytes())?;
        stdout.flush()?;
        if terminal {
            break;
        }
    }
    Ok(())
}
