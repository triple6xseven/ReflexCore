//! Scoped engineering decisions with explicit evidence and on-demand validation.
#[path = "repository_knowledge.rs"]
mod repository_knowledge;

use super::{git, Inputs, Result};
use rusqlite::{params, Connection, OpenFlags};
use serde_json::{json, Value};
use std::path::Path;

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS engineering_memory_v1(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    worktree TEXT NOT NULL,
    branch TEXT NOT NULL,
    component TEXT NOT NULL,
    topic TEXT NOT NULL,
    kind TEXT NOT NULL,
    statement TEXT NOT NULL,
    reference TEXT NOT NULL,
    dependencies TEXT NOT NULL,
    commit_sha TEXT NOT NULL,
    source_revision TEXT NOT NULL,
    validated_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE INDEX IF NOT EXISTS engineering_memory_topic
ON engineering_memory_v1(worktree,branch,component,topic,id);
";

pub(super) fn valid_topic(topic: &str) -> bool {
    !topic.is_empty()
        && topic.len() <= 64
        && topic
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
}

fn ancestry(base: &str, head: &str) -> bool {
    std::process::Command::new("git")
        .args(["merge-base", "--is-ancestor", base, head])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

pub(super) fn run(
    action: &str,
    topic: &str,
    args: &[String],
    db_path: &Path,
    tree: &str,
    component: &str,
    observation: &(String, Inputs),
) -> Result<Value> {
    let (source_revision, inputs) = observation;
    let branch = String::from_utf8(git(&["rev-parse", "--abbrev-ref", "HEAD"])?)?
        .trim()
        .to_owned();
    let commit = String::from_utf8(git(&["rev-parse", "HEAD"])?)?
        .trim()
        .to_owned();
    if branch == "HEAD" {
        return Err("Engineering memory requires a named branch".into());
    }
    if action == "remember" {
        let [kind, statement, reference, rest @ ..] = args else {
            return Err("Expected kind, statement and source reference".into());
        };
        if !matches!(
            kind.as_str(),
            "decision"
                | "defect"
                | "regression"
                | "experiment"
                | "performance"
                | "constraint"
                | "contract"
                | "compatibility"
                | "milestone"
                | "research"
                | "unresolved"
                | "invalidation"
        ) || statement.is_empty()
            || statement.len() > 320
            || statement.chars().any(char::is_control)
            || rest.len() > 5
        {
            return Err("Invalid engineering memory record".into());
        }
        let mut dependencies = Inputs::new();
        // Root engineering instructions are part of the authority for every record.
        for path in std::iter::once(reference).chain(rest).chain(
            ["AGENTS.md", "AGENTS.override.md"]
                .iter()
                .filter_map(|name| inputs.get_key_value(*name).map(|(key, _)| key)),
        ) {
            let digest = inputs
                .get(path)
                .ok_or("Reference is outside the selected component")?;
            if path == reference && digest == "missing" {
                return Err("Reference is missing".into());
            }
            dependencies.insert(path.clone(), digest.clone());
        }
        let mut db = Connection::open(db_path)?;
        db.busy_timeout(std::time::Duration::from_secs(2))?;
        let tx = db.transaction()?;
        tx.execute_batch(SCHEMA)?;
        let count: u32 = tx.query_row("SELECT count(*) FROM engineering_memory_v1", [], |row| {
            row.get(0)
        })?;
        if count >= 512 {
            return Err(
                "Engineering memory is full; archive the repository database before adding records"
                    .into(),
            );
        }
        tx.execute("INSERT INTO engineering_memory_v1(worktree,branch,component,topic,kind,statement,reference,dependencies,commit_sha,source_revision)
            VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)",params![tree,branch,component,topic,kind,statement,reference,serde_json::to_string(&dependencies)?,commit,source_revision])?;
        let id = tx.last_insert_rowid();
        tx.commit()?;
        return Ok(json!({"schema":1,"id":id,"tree":tree,"scope":component}));
    }
    let mut records = Vec::new();
    if db_path.exists() {
        let db = Connection::open_with_flags(db_path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
        let exists:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name='engineering_memory_v1' AND type='table')",[],|r|r.get(0))?;
        if exists {
            let mut query=db.prepare("SELECT id,kind,statement,reference,dependencies,commit_sha,validated_at,source_revision,worktree FROM engineering_memory_v1
                WHERE (worktree=?1 OR ?5) AND branch=?2 AND component=?3 AND topic=?4 ORDER BY id DESC LIMIT 4")?;
            let mut rows = query.query(params![
                tree,
                branch,
                component,
                topic,
                action == "recall-history"
            ])?;
            let mut seen_local = false;
            while let Some(row) = rows.next()? {
                let kind: String = row.get(1)?;
                let dependency_json: String = row.get(4)?;
                let recorded_commit: String = row.get(5)?;
                let dependencies: Inputs = serde_json::from_str(&dependency_json)?;
                let unchanged = dependencies
                    .iter()
                    .all(|(path, digest)| inputs.get(path) == Some(digest));
                let origin_tree: String = row.get(8)?;
                let status = if origin_tree != tree {
                    "historical"
                } else if seen_local {
                    "superseded"
                } else if kind == "invalidation" {
                    "invalidated"
                } else if unchanged
                    && (recorded_commit == commit || ancestry(&recorded_commit, &commit))
                {
                    "active"
                } else if matches!(kind.as_str(), "performance" | "experiment") {
                    "historical"
                } else if !unchanged {
                    "stale"
                } else {
                    "uncertain"
                };
                seen_local |= origin_tree == tree;
                records.push(json!({"id":row.get::<_,i64>(0)?,"kind":kind,"statement":row.get::<_,String>(2)?,
                    "reference":row.get::<_,String>(3)?,"origin_tree":origin_tree,"commit":recorded_commit,"source_revision":row.get::<_,String>(7)?,"created_and_validated_unix":row.get::<_,i64>(6)?,
                    "dependencies":dependencies.keys().collect::<Vec<_>>(),"status":status}));
            }
        }
    }
    let changes = if let [base] = args {
        if base.len() != 40
            || !base
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err("Expected full lowercase commit hash".into());
        }
        if ancestry(base, &commit) {
            let range = format!("{base}..{commit}");
            let mut log = vec!["log", "-17", "--format=%H", &range, "--"];
            log.extend(inputs.keys().map(String::as_str));
            let revisions = String::from_utf8(git(&log)?)?;
            let mut diff = vec!["diff", "--name-only", "-z", base, &commit, "--"];
            diff.extend(inputs.keys().map(String::as_str));
            let affected = String::from_utf8(git(&diff)?)?;
            json!({"base":base,"head":commit,"status":"comparable",
                "commits":revisions.lines().take(16).collect::<Vec<_>>(),
                "more_commits":revisions.lines().count()>16,
                "affected":affected.split_terminator('\0').collect::<Vec<_>>()})
        } else {
            json!({"base":base,"head":commit,"status":"unknown_or_diverged"})
        }
    } else {
        Value::Null
    };
    let knowledge = repository_knowledge::recall(
        db_path.parent().ok_or("Missing Git common directory")?,
        &commit,
        component,
        topic,
    )?;
    if !knowledge.is_empty() {
        records.truncate(2);
    }
    Ok(
        json!({"schema":1,"tree":tree,"scope":component,"branch":branch,"topic":topic,"records":records,"knowledge":knowledge,"changes":changes}),
    )
}
