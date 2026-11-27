//! Worktree-local recovery observations for the developer bridge.
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::Read,
    os::windows::fs::MetadataExt,
    path::{Path, PathBuf},
    process::Command,
};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
const COMMON: &[&str] = &["AGENTS.md", "Cargo.toml", "Cargo.lock", "docs/ROADMAP.md"];
const BRIDGE: &[&str] = &[
    "src/main.rs",
    "src/dev_context.rs",
    "docs/CODEX-INTEGRATION.md",
];
const MCP: &[&str] = &[
    "tools/ReflexCore-Mcp.cs",
    "tools/ReflexCore-Mcp.ps1",
    "tools/ReflexCore-McpLab.cs",
    "tools/ReflexCore-Queue.cs",
    "ui/McpSettings.cs",
    "docs/MCP.md",
];

fn git(args: &[&str]) -> Result<Vec<u8>> {
    let result = Command::new("git").args(args).output()?;
    if !result.status.success() {
        return Err("Repository observation unavailable".into());
    }
    Ok(result.stdout)
}
fn git_path(flag: &str) -> Result<PathBuf> {
    Ok(fs::canonicalize(
        String::from_utf8(git(&["rev-parse", flag])?)?.trim(),
    )?)
}
fn field(h: &mut Sha256, bytes: &[u8]) {
    h.update((bytes.len() as u64).to_le_bytes());
    h.update(bytes);
}
fn revision(root: &Path, files: &[&str]) -> Result<String> {
    let mut h = Sha256::new();
    field(&mut h, b"reflex.dev.context.v1");
    field(&mut h, &git(&["rev-parse", "HEAD"])?);
    field(&mut h, &git(&["rev-parse", "--abbrev-ref", "HEAD"])?);
    let mut index_args = vec!["ls-files", "--stage", "-z", "--"];
    index_args.extend(COMMON.iter().chain(files).copied());
    field(&mut h, &git(&index_args)?);
    for file in COMMON.iter().chain(files) {
        field(&mut h, file.as_bytes());

        let mut path = root.to_owned();
        let mut missing = false;
        for part in Path::new(file).components() {
            path.push(part);
            match fs::symlink_metadata(&path) {
                Ok(m) if m.file_attributes() & 0x400 != 0 => return Err("Redirected input".into()),
                Ok(_) => (),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                    missing = true;
                    break;
                }
                Err(e) => return Err(e.into()),
            }
        }
        if missing {
            field(&mut h, b"missing");
            continue;
        }
        if !path.is_file() {
            return Err("Unsupported context input".into());
        }
        let mut bytes = Vec::new();
        fs::File::open(path)?
            .take(2_097_153)
            .read_to_end(&mut bytes)?;
        if bytes.len() > 2_097_152 {
            return Err("Context input exceeds budget".into());
        }
        field(&mut h, b"file");
        field(&mut h, &bytes);
    }
    Ok(format!("{:x}", h.finalize()))
}
pub(crate) fn run(args: &[String]) -> Result<()> {
    let [action, session, component, rest @ ..] = args else {
        return Err("Expected status or record, session ID and component".into());
    };
    if !(1..=64).contains(&session.len())
        || !session
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'-')
    {
        return Err("Invalid session ID".into());
    }
    let files = match component.as_str() {
        "bridge" => BRIDGE,
        "mcp" => MCP,
        _ => return Err("Unknown component".into()),
    };
    let event = match (action.as_str(), rest) {
        ("status" | "resume", []) => None,
        ("declare", [objective, next])
            if [objective, next]
                .iter()
                .all(|v| !v.is_empty() && v.len() <= 320 && !v.chars().any(char::is_control)) =>
        {
            None
        }
        ("record", [e])
            if matches!(
                e.as_str(),
                "mutation-started"
                    | "mutation-returned"
                    | "compaction"
                    | "interrupt"
                    | "build-started"
                    | "test-started"
                    | "build-returned"
                    | "test-returned"
                    | "turn-ended"
                    | "usage-limit"
            ) =>
        {
            Some(e)
        }
        _ => return Err("Unknown checkpoint operation".into()),
    };
    let root = git_path("--show-toplevel")?;
    if fs::canonicalize(".")? != root {
        return Err("Run from the worktree root".into());
    }
    let dir = git_path("--absolute-git-dir")?;
    let tree = format!("{:x}", Sha256::digest(dir.as_os_str().as_encoded_bytes()));
    let auto = action == "resume" && session == "auto";
    let mut session = format!("{:x}", Sha256::digest(session.as_bytes()));
    let rev = revision(&root, files)?;
    if revision(&root, files)? != rev {
        return Err("Uncertain: inputs changed during observation".into());
    }
    let db_path = dir.join("reflex-dev-context-v1.sqlite");
    let mut previous = None;
    let mut declared: Option<(String, String, String)> = None;
    let mut history = Vec::<String>::new();
    if event.is_some() || action == "declare" || db_path.exists() {
        let mut db = Connection::open(db_path)?;
        db.busy_timeout(std::time::Duration::from_secs(2))?;
        db.execute_batch("CREATE TABLE IF NOT EXISTS checkpoint(tree TEXT, session TEXT, component TEXT, revision TEXT, event TEXT, PRIMARY KEY(tree,session,component));")?;
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let version: i64 = tx.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        if version > 2 {
            return Err("Unsupported checkpoint schema".into());
        }
        if version < 2 {
            tx.execute_batch("CREATE TABLE IF NOT EXISTS intent(tree TEXT, session TEXT, component TEXT, objective TEXT, next TEXT, baseline TEXT, PRIMARY KEY(tree,session,component));
                CREATE TABLE IF NOT EXISTS observation(id INTEGER PRIMARY KEY, tree TEXT, session TEXT, component TEXT, revision TEXT, event TEXT);
                PRAGMA user_version=2;")?;
        }
        if auto {
            let mut q =
                tx.prepare("SELECT session FROM intent WHERE tree=?1 AND component=?2 LIMIT 2")?;
            let ids = q
                .query_map(params![tree, component], |r| r.get::<_, String>(0))?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            if ids.len() != 1 {
                println!(
                    "{}",
                    json!({"v":2,"checkpoint":if ids.is_empty() {"absent"} else {"ambiguous"}})
                );
                return Ok(());
            }
            session = ids[0].clone();
        }
        if action == "declare" {
            tx.execute(
                "INSERT OR REPLACE INTO intent VALUES(?1,?2,?3,?4,?5,?6)",
                params![tree, session, component, rest[0], rest[1], rev],
            )?;
            tx.execute("DELETE FROM intent WHERE rowid IN (SELECT rowid FROM intent ORDER BY rowid DESC LIMIT -1 OFFSET 256)",[])?;
        }
        if let Some(e) = event {
            tx.execute("INSERT INTO observation(tree,session,component,revision,event) SELECT ?1,?2,?3,?4,?5 WHERE NOT EXISTS(SELECT 1 FROM (SELECT revision,event FROM observation WHERE tree=?1 AND session=?2 AND component=?3 ORDER BY id DESC LIMIT 1) WHERE revision=?4 AND event=?5)",params![tree,session,component,rev,e])?;
            tx.execute("DELETE FROM observation WHERE id IN (SELECT id FROM observation ORDER BY id DESC LIMIT -1 OFFSET 1024)",[])?;
            tx.execute("INSERT INTO checkpoint VALUES(?1,?2,?3,?4,?5) ON CONFLICT(tree,session,component) DO UPDATE SET revision=excluded.revision,event=excluded.event WHERE revision<>excluded.revision OR event<>excluded.event", params![tree,session,component,rev,e])?;
            tx.execute("DELETE FROM checkpoint WHERE rowid IN (SELECT rowid FROM checkpoint ORDER BY rowid DESC LIMIT -1 OFFSET 256)", [])?;
        }
        previous = tx.query_row("SELECT revision,event FROM checkpoint WHERE tree=?1 AND session=?2 AND component=?3",params![tree,session,component],|r| Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?))).optional()?;
        if action == "resume" {
            declared=tx.query_row("SELECT objective,next,baseline FROM intent WHERE tree=?1 AND session=?2 AND component=?3",params![tree,session,component],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional()?;
            let mut q=tx.prepare("SELECT event FROM observation WHERE tree=?1 AND session=?2 AND component=?3 ORDER BY id DESC LIMIT 12")?;
            history = q
                .query_map(params![tree, session, component], |r| r.get(0))?
                .collect::<rusqlite::Result<Vec<String>>>()?;
        }
        tx.commit()?;
    }
    let freshness = match &previous {
        None => "absent",
        Some((r, _)) if r == &rev => "matching",
        _ => "changed",
    };
    if action == "resume" {
        println!(
            "{}",
            json!({"v":2,"scope":component,"tree":tree,"session_key":session,"revision":rev,"checkpoint":freshness,
            "declared":declared.map(|(objective,next,base)|json!({"objective":objective,"next":next,"source_changed_since_declaration":base!=rev})),
            "recent_events_newest_first":history,"effect":"unknown","references":files,"verified_evidence":null})
        );
        return Ok(());
    }
    println!(
        "{}",
        json!({"v":1,"tree":tree,"scope":component,"revision":rev,"checkpoint":freshness,"last_event":previous.map(|(_,e)|e),"effect":"unknown"})
    );
    Ok(())
}
