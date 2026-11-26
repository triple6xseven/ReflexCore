use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    error::Error,
    fmt, fs,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
    time::{SystemTime, UNIX_EPOCH},
};

type Result<T> = std::result::Result<T, Box<dyn Error>>;
static NEXT_ID: AtomicU64 = AtomicU64::new(0);
const ACTION_SCHEMA: &str = "reflexcore.uia.exchange.v1";

#[derive(Debug, Clone, Copy)]
pub(crate) enum Fault {
    Cancelled,
    CancelledUnknown,
    VerificationFailed,
    PreconditionFailed,
    EffectUnknown,
    FocusLost,
    Infrastructure,
}
impl Fault {
    pub(crate) fn code(self) -> &'static str {
        match self {
            Self::Cancelled => "operator_cancelled",
            Self::CancelledUnknown => "cancelled_effect_unknown",
            Self::VerificationFailed => "verification_failed",
            Self::PreconditionFailed => "precondition_failed",
            Self::EffectUnknown => "effect_unknown",
            Self::FocusLost => "focus_lost",
            Self::Infrastructure => "infrastructure_error",
        }
    }
}
impl fmt::Display for Fault {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.code())
    }
}
impl Error for Fault {}

pub(crate) fn run_id() -> String {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    format!(
        "{timestamp:032x}{:08x}{:016x}",
        std::process::id(),
        NEXT_ID.fetch_add(1, Ordering::Relaxed)
    )
}

pub(crate) fn task_id() -> Option<String> {
    let manifest = std::env::var("REFLEXCORE_QUEUE_MANIFEST").ok()?;
    job_id(&manifest).map(str::to_owned)
}

fn job_id(manifest: &str) -> Option<&str> {
    let id = manifest.strip_suffix(".job")?;
    let (stamp, nonce) = id.split_once('-')?;
    (stamp.len() == 17
        && stamp.bytes().all(|b| b.is_ascii_digit())
        && nonce.len() == 32
        && nonce
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)))
    .then_some(id)
}

pub(crate) fn cancelled() -> bool {
    if std::env::var_os("REFLEXCORE_QUEUE_MANIFEST").is_none() {
        return false;
    }
    let Some(id) = task_id() else { return true };
    claim_cancelled(std::path::Path::new("data/bridge"), &id)
}

fn claim_cancelled(bridge: &std::path::Path, id: &str) -> bool {
    !bridge.join("running").join(format!("{id}.job")).is_file()
        || bridge
            .join("queue-requests")
            .join(format!("{id}.cancel"))
            .is_file()
}

pub(crate) fn guard_cancelled() -> bool {
    let Ok(manifest) = std::env::var("REFLEXCORE_GUARD_MANIFEST") else {
        return false;
    };
    job_id(&manifest).is_none_or(|id| claim_cancelled(std::path::Path::new("data/bridge"), id))
}

pub(crate) fn check_cancel() -> Result<()> {
    if cancelled() {
        return Err(Fault::Cancelled.into());
    }
    Ok(())
}

pub(crate) fn write_receipt(run: &str, fault: Option<Fault>, verified: bool) -> Result<()> {
    write_goal_receipt(run, fault, verified, None)
}

pub(crate) fn write_goal_receipt(run: &str, fault: Option<Fault>, verified: bool,
    evidence: Option<&crate::skill_registry::saved_text::Evidence<'_>>) -> Result<()> {
    let Some(id) = task_id() else { return Ok(()) };
    let outcome = match fault {
        Some(Fault::Cancelled | Fault::CancelledUnknown) => "cancelled",
        Some(Fault::EffectUnknown) => "unverified",
        Some(_) => "failed",
        None => {
            if verified {
                "verified"
            } else {
                "unverified"
            }
        }
    };
    let verification = match fault {
        Some(Fault::VerificationFailed) => "failed",
        Some(Fault::EffectUnknown | Fault::CancelledUnknown) => "unknown",
        None if verified => "verified",
        _ => "not_confirmed",
    };
    let mut document = serde_json::json!({
        "schema": "reflexcore.task.receipt.v1", "task_id": id, "run_id": run,
        "stage": "goal", "outcome": outcome, "verification": verification,
        "reason": fault.map(Fault::code).unwrap_or(if verified { "verified_goal" } else { "no_effect_evidence" })
    });
    if let Some(evidence) = evidence {
        document["skill"] = serde_json::to_value(evidence)?;
    }
    publish_receipt(&id, run, &document)
}

pub(crate) fn publish_receipt(id: &str, run: &str, document: &Value) -> Result<()> {
    let staging = format!("data/bridge/running/{id}.{run}.tmp");
    let dest = format!("data/bridge/running/{id}.receipt.json");
    fs::write(&staging, serde_json::to_vec(&document)?)?;
    if let Err(error) = fs::rename(&staging, dest) {
        let _ = fs::remove_file(staging);
        return Err(error.into());
    }
    Ok(())
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ActionEnvelope {
    schema: String,
    run_id: String,
    action_id: usize,
    pub(crate) payload: Value,
}
impl ActionEnvelope {
    pub(crate) fn decode(bytes: &[u8]) -> Result<Self> {
        let reply: Self = serde_json::from_slice(bytes)?;
        if reply.schema != ACTION_SCHEMA
            || reply.action_id == 0
            || reply.run_id.len() != 56
            || !reply.run_id.bytes().all(|b| b.is_ascii_hexdigit())
        {
            return Err("Invalid action exchange envelope".into());
        }
        Ok(reply)
    }
}

pub(crate) struct ActionExchange {
    dir: PathBuf,
    run_id: String,
    action_id: usize,
}
impl ActionExchange {
    pub(crate) fn new(run: &str, action_id: usize) -> Result<Self> {
        let dir = std::env::temp_dir().join(format!("reflexcore-act-{}", run_id()));
        fs::create_dir(&dir)?;
        Ok(Self {
            dir,
            run_id: run.to_owned(),
            action_id,
        })
    }
    pub(crate) fn path(&self) -> PathBuf {
        self.dir.join("response.json")
    }
    pub(crate) fn encode(&self, payload: Value) -> Result<String> {
        Ok(serde_json::to_string(&ActionEnvelope {
            schema: ACTION_SCHEMA.into(),
            run_id: self.run_id.clone(),
            action_id: self.action_id,
            payload,
        })?)
    }
    pub(crate) fn read(&self) -> Result<Value> {
        use std::io::Read;
        let mut bytes = Vec::new();
        fs::File::open(self.path())?
            .take(262_145)
            .read_to_end(&mut bytes)?;
        if bytes.len() > 262_144 {
            return Err("UIA response exceeds limit".into());
        }
        let reply = ActionEnvelope::decode(&bytes)?;
        if reply.run_id != self.run_id
            || reply.action_id != self.action_id
            || reply.payload["schema"] != "reflexcore.uia.action.v1"
        {
            return Err("UIA response does not belong to this action".into());
        }
        Ok(reply.payload)
    }
}
impl Drop for ActionExchange {
    fn drop(&mut self) {
        let _ = fs::remove_file(self.path());
        let _ = fs::remove_file(self.path().with_extension("tmp"));
        let _ = fs::remove_dir(&self.dir);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn overlapping_requests_reject_foreign_stale_truncated_and_missing_records() {
        let run = run_id();
        let first = ActionExchange::new(&run, 1).unwrap();
        let second = ActionExchange::new(&run, 2).unwrap();
        let other = ActionExchange::new(&run_id(), 2).unwrap();
        let good = serde_json::json!({"schema":"reflexcore.uia.action.v1", "status":"issued"});
        assert!(first.read().is_err());
        for invalid in [
            first.encode(good.clone()).unwrap(),
            other.encode(good.clone()).unwrap(),
            "{".into(),
        ] {
            fs::write(second.path(), invalid).unwrap();
            assert!(second.read().is_err());
        }
        let mut first_worker = spawn_test_worker(&first, good.clone());
        let mut second_worker = spawn_test_worker(&second, good.clone());
        assert!(second_worker.wait().unwrap().success());
        assert!(first_worker.wait().unwrap().success());
        assert_eq!(first.read().unwrap(), good);
        assert_eq!(second.read().unwrap(), good);
    }

    fn spawn_test_worker(exchange: &ActionExchange, value: Value) -> std::process::Child {
        use std::process::{Command, Stdio};
        Command::new(std::env::current_exe().unwrap())
            .args(["task_integrity::tests::test_worker", "--exact"])
            .env("REFLEXCORE_TEST_ACTION_FILE", exchange.path())
            .env(
                "REFLEXCORE_TEST_ACTION_REPLY",
                exchange.encode(value).unwrap(),
            )
            .stdout(Stdio::null())
            .spawn()
            .unwrap()
    }

    #[test]
    fn test_worker() {
        let Some(file) = std::env::var_os("REFLEXCORE_TEST_ACTION_FILE") else {
            return;
        };
        let path = PathBuf::from(file);
        let staging = path.with_extension("tmp");
        fs::write(
            &staging,
            std::env::var("REFLEXCORE_TEST_ACTION_REPLY").unwrap(),
        )
        .unwrap();
        // Replace the intentionally truncated fixture response before publishing.
        if path.exists() {
            fs::remove_file(&path).unwrap();
        }
        fs::rename(staging, path).unwrap();
    }

    #[test]
    fn cancelled_claim_cannot_start_a_later_action() {
        let scratch = ActionExchange::new(&run_id(), 1).unwrap();
        let bridge = scratch.dir.join("bridge");
        fs::create_dir_all(bridge.join("running")).unwrap();
        fs::create_dir_all(bridge.join("queue-requests")).unwrap();
        let job = bridge.join("running/test.job");
        let cancel = bridge.join("queue-requests/test.cancel");
        assert!(claim_cancelled(&bridge, "test"));
        fs::write(&job, "RUN\nsynthetic.ps1").unwrap();
        assert!(!claim_cancelled(&bridge, "test"));
        fs::write(&cancel, "").unwrap();
        assert!(claim_cancelled(&bridge, "test"));
        fs::remove_file(cancel).unwrap();
        fs::remove_file(job).unwrap();
        assert!(claim_cancelled(&bridge, "test"));
        fs::remove_dir(bridge.join("running")).unwrap();
        fs::remove_dir(bridge.join("queue-requests")).unwrap();
        fs::remove_dir(bridge).unwrap();
    }
}
