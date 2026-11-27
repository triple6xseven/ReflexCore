//! Bounded project-hook telemetry. No Git calls or model requests on the hook path.
use rusqlite::{params, Connection};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::Read,
    path::Path,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

pub fn capture(root: &Path, diagnostic: bool) -> Result<()> {
    let start = Instant::now();
    let arrived = SystemTime::now().duration_since(UNIX_EPOCH)?.as_millis() as i64;
    let exe = std::env::current_exe()?;
    let install = exe.parent().ok_or("missing observer directory")?;
    if install.file_name().and_then(|n| n.to_str()) != Some("reflex-observer") {
        return Err("not installed".into());
    }
    let private = install.parent().ok_or("missing worktree directory")?;
    let mut bytes = Vec::new();
    std::io::stdin().take(32769).read_to_end(&mut bytes)?;
    let payload = if bytes.len() <= 32768 {
        serde_json::from_slice(&bytes).ok()
    } else {
        None
    };
    let data: serde_json::Value = payload.unwrap_or_default();
    let field = |name: &str| data.get(name).and_then(|v| v.as_str()).unwrap_or("");
    let event = match field("hook_event_name") {
        e @ ("PreToolUse" | "PostToolUse" | "PreCompact" | "Interrupt" | "Stop") => e,
        _ => "unknown",
    };
    let tool = match field("tool_name") {
        "apply_patch" | "Edit" | "Write" => "mutation",
        "exec_command" | "shell_command" | "Bash" => "shell",
        "" => "none",
        _ => "other",
    };
    let id = field("session_id");
    let valid = !id.is_empty()
        && id.len() <= 64
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-');
    let matched = fs::canonicalize(root)
        .ok()
        .zip(fs::canonicalize(field("cwd")).ok())
        .is_some_and(|(a, b)| a == b);
    let reason = if data.is_null() {
        "invalid_payload"
    } else if !matched {
        "wrong_worktree"
    } else if !valid {
        "missing_session"
    } else if event == "unknown" {
        "unknown_event"
    } else {
        "accepted"
    };
    let outcome = match (event, tool) {
        ("Interrupt", _) => Some("interrupt"),
        ("Stop", _) => Some("turn-ended"),
        ("PreCompact", _) => Some("compaction"),
        ("PreToolUse", "mutation") => Some("mutation-started"),
        ("PostToolUse", "mutation") => Some("mutation-returned"),
        ("PreToolUse" | "PostToolUse", "shell") => {
            let cmd = data["tool_input"]["cmd"]
                .as_str()
                .or(data["tool_input"]["command"].as_str())
                .unwrap_or("");
            let mut words = cmd.split_ascii_whitespace();
            if cmd.contains([';', '|', '&', '\r', '\n', '<', '>']) || words.next() != Some("cargo")
            {
                None
            } else {
                match (event, words.next()) {
                    ("PreToolUse", Some("test")) => Some("test-started"),
                    ("PostToolUse", Some("test")) => Some("test-returned"),
                    ("PreToolUse", Some("build")) => Some("build-started"),
                    ("PostToolUse", Some("build")) => Some("build-returned"),
                    _ => None,
                }
            }
        }
        _ => None,
    };
    let mut db = Connection::open(private.join("reflex-hook-arrivals.sqlite"))?;
    db.busy_timeout(Duration::from_millis(250))?;
    let tx = db.transaction()?;
    if reason == "accepted" {
        if let Some(kind) = outcome {
            tx.execute_batch(
                "CREATE TABLE IF NOT EXISTS journal(session TEXT,kind TEXT,at_ms INTEGER)",
            )?;
            tx.execute(
                "INSERT INTO journal VALUES(?1,?2,?3)",
                params![
                    format!("{:x}", Sha256::digest(id.as_bytes())),
                    kind,
                    arrived
                ],
            )?;
            tx.execute("DELETE FROM journal WHERE rowid IN(SELECT rowid FROM journal ORDER BY rowid DESC LIMIT -1 OFFSET 256)",[])?;
        }
    }
    tx.commit()?;
    if diagnostic {
        let tx = db.transaction()?;
        tx.execute_batch("CREATE TABLE IF NOT EXISTS diagnostic(event TEXT,at_ms INTEGER,tool TEXT,has_session INTEGER,matched INTEGER,reason TEXT,elapsed_us INTEGER)")?;
        let code = if reason == "accepted" {
            if outcome.is_some() {
                "persisted"
            } else {
                "ignored_operation"
            }
        } else {
            reason
        };
        tx.execute(
            "INSERT INTO diagnostic VALUES(?1,?2,?3,?4,?5,?6,?7)",
            params![
                event,
                arrived,
                tool,
                valid,
                matched,
                code,
                start.elapsed().as_micros() as i64
            ],
        )?;
        tx.execute("DELETE FROM diagnostic WHERE rowid IN(SELECT rowid FROM diagnostic ORDER BY rowid DESC LIMIT -1 OFFSET 128)",[])?;
        tx.commit()?;
    }
    Ok(())
}
