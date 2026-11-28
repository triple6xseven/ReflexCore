//! Rebuildable retrieval index for checked-in engineering records.
use super::{ancestry, git, Result};
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    path::Path,
    process::{Command, Stdio},
};

const CATALOG: &str = "docs/engineering-knowledge.json";
const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS catalog(
    blob TEXT PRIMARY KEY, indexed INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS knowledge(
    blob TEXT, component TEXT, topic TEXT, id TEXT, record TEXT,
    PRIMARY KEY(blob,component,topic,id)
);";

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Record {
    id: String,
    component: String,
    topic: String,
    kind: String,
    statement: String,
    rationale: String,
    reference: String,
    commit: String,
    dependencies: Vec<String>,
    created: String,
    validated: String,
    #[serde(default)]
    supersedes: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Catalog {
    schema: u8,
    records: Vec<Record>,
}

fn plain(text: &str, limit: usize) -> bool {
    !text.is_empty() && text.len() <= limit && !text.chars().any(char::is_control)
}

fn oid(value: &str) -> bool {
    value.len() == 40
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn path(value: &str) -> bool {
    value.len() <= 96
        && !value.contains("..")
        && !value.contains("//")
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"/_-. ".contains(&b))
        && (["src/", "tools/", "tasks/", "docs/", "examples/"]
            .iter()
            .any(|prefix| value.starts_with(prefix))
            || matches!(
                value,
                "AGENTS.md" | "Cargo.toml" | "Cargo.lock" | "CHANGELOG.md"
            ))
}

impl Record {
    fn valid(&self) -> bool {
        super::valid_topic(&self.id)
            && super::valid_topic(&self.topic)
            && matches!(self.component.as_str(), "bridge" | "mcp" | "universal")
            && matches!(
                self.kind.as_str(),
                "decision"
                    | "alternative"
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
            )
            && plain(&self.statement, 300)
            && plain(&self.rationale, 300)
            && oid(&self.commit)
            && path(&self.reference)
            && !self.dependencies.is_empty()
            && self.dependencies.len() <= 6
            && self.dependencies.iter().all(|p| path(p))
            && plain(&self.created, 10)
            && plain(&self.validated, 10)
            && self
                .supersedes
                .as_ref()
                .is_none_or(|id| super::valid_topic(id) && id != &self.id)
    }

    fn status(&self, head: &str, superseded: bool) -> &'static str {
        if superseded {
            return "superseded";
        }
        if !ancestry(&self.commit, head) {
            return "uncertain";
        }
        if git(&[
            "cat-file",
            "-e",
            &format!("{}:{}", self.commit, self.reference),
        ])
        .is_err()
        {
            return "uncertain";
        }
        if self.kind == "invalidation" {
            return "invalidated";
        }
        if matches!(
            self.kind.as_str(),
            "performance" | "experiment" | "milestone" | "alternative" | "defect"
        ) {
            return "historical";
        }
        // Verify both the index and the current working content against the evidence commit.
        for flags in [
            &["--cached", self.commit.as_str()][..],
            &[self.commit.as_str()][..],
        ] {
            let status = Command::new("git")
                .args(["--literal-pathspecs", "diff", "--quiet"])
                .args(flags)
                .arg("--")
                .args(&self.dependencies)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
            match status.ok().and_then(|exit| exit.code()) {
                Some(0) => {}
                Some(1) => return "stale",
                _ => return "uncertain",
            }
        }
        "active"
    }
}

pub(super) fn recall(
    common: &Path,
    head: &str,
    component: &str,
    topic: &str,
) -> Result<Vec<Value>> {
    let pointer = format!("{head}:{CATALOG}");
    let Ok(blob) = git(&["rev-parse", "--verify", &pointer]) else {
        return Ok(Vec::new());
    };
    let blob = String::from_utf8(blob)?;
    let blob = blob.trim();
    let size = String::from_utf8(git(&["cat-file", "-s", blob])?)?
        .trim()
        .parse::<usize>()?;
    if !oid(blob) || size > 65_536 {
        return Err("Engineering catalog exceeds its budget".into());
    }
    let mut db = Connection::open(common.join("reflex-knowledge-index-v1.sqlite"))?;
    db.busy_timeout(std::time::Duration::from_secs(2))?;
    db.execute_batch(SCHEMA)?;
    let present: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM catalog WHERE blob=?1)",
        [blob],
        |r| r.get(0),
    )?;
    if !present {
        let catalog: Catalog = serde_json::from_slice(&git(&["cat-file", "blob", blob])?)?;
        let mut ids = HashMap::new();
        if catalog.schema != 1 || catalog.records.len() > 96 {
            return Err("Invalid checked-in engineering catalog".into());
        }
        for record in &catalog.records {
            let scope = (&record.component, &record.topic);
            if !record.valid()
                || record
                    .supersedes
                    .as_ref()
                    .is_some_and(|id| ids.get(id) != Some(&scope))
                || ids.insert(&record.id, scope).is_some()
            {
                return Err("Invalid checked-in engineering catalog".into());
            }
        }
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        tx.execute(
            "INSERT OR IGNORE INTO catalog VALUES(?1,unixepoch())",
            [blob],
        )?;
        for record in catalog.records {
            tx.execute(
                "INSERT OR IGNORE INTO knowledge VALUES(?1,?2,?3,?4,?5)",
                params![
                    blob,
                    record.component,
                    record.topic,
                    record.id,
                    serde_json::to_string(&record)?
                ],
            )?;
        }
        tx.execute(
            "DELETE FROM catalog WHERE blob IN
            (SELECT blob FROM catalog WHERE blob<>?1 ORDER BY indexed DESC,blob LIMIT -1 OFFSET 3)",
            [blob],
        )?;
        tx.execute(
            "DELETE FROM knowledge WHERE blob NOT IN (SELECT blob FROM catalog)",
            [],
        )?;
        tx.commit()?;
    }
    let mut query=db.prepare("SELECT record FROM knowledge WHERE blob=?1 AND component=?2 AND topic=?3 ORDER BY id DESC LIMIT 2")?;
    let mut rows = query.query(params![blob, component, topic])?;
    let mut result = Vec::new();
    while let Some(row) = rows.next()? {
        let record: Record = serde_json::from_str(&row.get::<_, String>(0)?)?;
        if !record.valid() {
            return Err("Invalid indexed engineering record".into());
        }
        let newer:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM knowledge
            WHERE blob=?1 AND component=?2 AND topic=?3 AND json_extract(record,'$.supersedes')=?4)",
            params![blob,component,topic,record.id],|r|r.get(0))?;
        let status = record.status(head, newer);
        result.push(json!({"id":record.id,"schema":1,"kind":record.kind,"statement":record.statement,
            "rationale":record.rationale,"source":record.reference,"commit":record.commit,
            "dependencies":record.dependencies,"created":record.created,"validated":record.validated,"status":status}));
    }
    Ok(result)
}
