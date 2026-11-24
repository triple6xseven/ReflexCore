//! Bounded online reliability estimates for existing, independently checked Flow skills.
use crate::agent::Goal;
use rusqlite::{params, Connection, OpenFlags};
use sha2::{Digest, Sha256};
use std::{fs, io::Read, path::Path, time::Duration};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
const DB: &str = "data/private/goal-memory-v1.sqlite3";
const LIMIT: i64 = 256;

fn flow_digest(flow: &str) -> Option<Vec<u8>> {
    let bytes = if flow == "demo" {
        include_bytes!("../examples/smoke_flow.json").to_vec()
    } else {
        let file = fs::File::open(flow).ok()?;
        let limit = 2 * 1024 * 1024;
        if file.metadata().ok()?.len() > limit {
            return None;
        }
        let mut data = Vec::new();
        file.take(limit + 1).read_to_end(&mut data).ok()?;
        if data.len() > limit as usize {
            return None;
        }
        data
    };
    if !crate::flow::has_terminal_assertion(&bytes) {
        return None;
    }
    Some(Sha256::digest(&bytes).to_vec())
}

pub(super) struct Memory {
    db: Connection,
    goal_key: Vec<u8>,
}
impl Memory {
    // Planning an unseen goal stays read-only, including on a fresh installation.
    pub(super) fn open(goal: &Goal, writing: bool) -> Result<Option<Self>> {
        let path = Path::new(DB);
        if !writing && !path.exists() {
            return Ok(None);
        }
        let db = if writing {
            fs::create_dir_all(path.parent().expect("fixed database path"))?;
            Connection::open(path)?
        } else {
            Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?
        };
        db.busy_timeout(Duration::from_millis(100))?;
        if writing {
            db.execute_batch(
                "CREATE TABLE IF NOT EXISTS routes (
                goal BLOB NOT NULL, slot INTEGER NOT NULL, flow BLOB NOT NULL,
                passes INTEGER NOT NULL, misses INTEGER NOT NULL, touched INTEGER NOT NULL,
                PRIMARY KEY(goal,slot)) WITHOUT ROWID;",
            )?;
        }
        let goal_key = Sha256::digest(serde_json::to_vec(goal)?).to_vec();
        Ok(Some(Self { db, goal_key }))
    }
    pub(super) fn apply(&self, goal: &mut Goal) -> Result<()> {
        let mut query = self.db.prepare(
            "SELECT slot,flow,passes,misses FROM routes WHERE goal=?1 AND misses>0 LIMIT 256",
        )?;
        let mut rows = query.query([&self.goal_key])?;
        while let Some(row) = rows.next()? {
            let slot = usize::try_from(row.get::<_, i64>(0)?)?;
            let Some(skill) = goal.skills.get_mut(slot) else {
                continue;
            };
            let saved: Vec<u8> = row.get(1)?;
            if flow_digest(&skill.flow).as_ref() != Some(&saved) {
                continue;
            }
            let passes: u32 = row.get(2)?;
            let misses: u32 = row.get(3)?;
            // Regularized miss-to-pass ratio. Bound the penalty and preserve positive costs.
            let penalty = skill.cost * misses.min(64) / (1 + passes.min(64));
            skill.cost = skill
                .cost
                .saturating_add(penalty.min(skill.cost * 4))
                .min(10_000);
        }
        Ok(())
    }
    pub(super) fn fingerprint(flow: &str) -> Option<Vec<u8>> {
        flow_digest(flow)
    }
    pub(super) fn record(&mut self, slot: usize, flow: &[u8], passed: bool) -> Result<()> {
        let tx = self.db.transaction()?;
        // Decay saturated histories together so a repaired skill can recover.
        tx.execute("INSERT INTO routes VALUES (?1,?2,?3,?4,?5,1+coalesce((SELECT max(touched) FROM routes),0))
            ON CONFLICT(goal,slot) DO UPDATE SET
              passes=excluded.passes+CASE WHEN flow<>excluded.flow THEN 0 WHEN passes+misses>=64 THEN passes/2 ELSE passes END,
              misses=excluded.misses+CASE WHEN flow<>excluded.flow THEN 0 WHEN passes+misses>=64 THEN misses/2 ELSE misses END,
              flow=excluded.flow,touched=excluded.touched",
            params![self.goal_key, i64::try_from(slot)?, flow, passed as i32, (!passed) as i32])?;
        tx.execute(
            "DELETE FROM routes WHERE (goal,slot) IN (
            SELECT goal,slot FROM routes ORDER BY touched DESC LIMIT -1 OFFSET ?1)",
            [LIMIT],
        )?;
        tx.commit()?;
        Ok(())
    }
}

const REPLAY_PER_ENVIRONMENT: i64 = 1024;

pub(crate) fn read_lab_checkpoint(id: &str) -> Result<Vec<u8>> {
    let db = Connection::open_with_flags(Path::new(DB), OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    let bytes: Vec<u8> = db.query_row(
        "SELECT weights FROM motion_checkpoints_v1 WHERE id = ?1 AND format = 1
         AND length(weights) <= 8192", [id], |row| row.get(0))?;
    if format!("{:x}", Sha256::digest(&bytes)) != id {
        return Err("Checkpoint digest mismatch".into());
    }
    Ok(bytes)
}

pub(crate) fn lab_reliability() -> Result<Vec<(String, String, u32, u32)>> {
    if !Path::new(DB).exists() {
        return Ok(Vec::new());
    }
    let db = Connection::open_with_flags(Path::new(DB), OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    let exists: bool = db.query_row("SELECT EXISTS(SELECT 1 FROM sqlite_master
        WHERE type='table' AND name='motion_replay_v1')", [], |row| row.get(0))?;
    if !exists { return Ok(Vec::new()); }
    let mut query = db.prepare("SELECT environment, skill, count(*), sum(json_extract(sample, '$.verified'))
        FROM motion_replay_v1 WHERE version = 1
        GROUP BY environment, skill ORDER BY environment, skill")?;
    let rows = query.query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)))?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

pub(crate) fn record_motion<'a>(
    samples: impl IntoIterator<Item = &'a crate::learning::Experience>,
    checkpoint: Option<(&str, &[u8])>,
    skill: &'static str,
) -> Result<()> {
    let path = Path::new(DB);
    fs::create_dir_all(path.parent().expect("fixed database path"))?;
    let mut db = Connection::open(path)?;
    db.busy_timeout(Duration::from_millis(100))?;
    let tx = db.transaction()?;
    tx.execute_batch(
        "CREATE TABLE IF NOT EXISTS motion_replay_v1 (
            seq INTEGER PRIMARY KEY, environment TEXT NOT NULL,
            skill TEXT NOT NULL, version INTEGER NOT NULL, sample TEXT NOT NULL);
         CREATE TABLE IF NOT EXISTS motion_checkpoints_v1 (
            id TEXT PRIMARY KEY, weights BLOB NOT NULL, format INTEGER NOT NULL);",
    )?;
    let mut statement = tx.prepare("INSERT INTO motion_replay_v1(environment,skill,version,sample)
        VALUES (?1, ?2, 1, ?3)")?;
    for sample in samples {
        statement.execute(params![sample.environment, skill, serde_json::to_string(sample)?])?;
    }
    drop(statement);
    for context in ["ground_v1", "arena_v1", "cs16_offline_v1"] {
        tx.execute("DELETE FROM motion_replay_v1 WHERE seq IN (
            SELECT seq FROM motion_replay_v1 WHERE environment = ?1 ORDER BY seq DESC LIMIT -1 OFFSET ?2)",
            params![context, REPLAY_PER_ENVIRONMENT])?;
    }
    if let Some((version, weights)) = checkpoint {
        tx.execute("INSERT OR IGNORE INTO motion_checkpoints_v1 VALUES (?1, ?2, 1)", params![version, weights])?;
        tx.execute("DELETE FROM motion_checkpoints_v1 WHERE rowid NOT IN
                    (SELECT rowid FROM motion_checkpoints_v1 ORDER BY rowid DESC LIMIT 4)", [])?;
    }
    tx.commit()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn failure_changes_route_and_changed_content_loses_penalty() {
        let mut goal =
            crate::agent::parse(include_str!("../examples/goal_agent_demo.json")).unwrap();
        let mut alternative = goal.skills[0].clone();
        alternative.id = "alternative".into();
        alternative.cost = 2;
        goal.skills.push(alternative);
        let mut db = Memory {
            db: Connection::open_in_memory().unwrap(),
            goal_key: vec![1],
        };
        db.db.execute_batch("CREATE TABLE routes(goal BLOB,slot INTEGER,flow BLOB,passes INTEGER,misses INTEGER,touched INTEGER,PRIMARY KEY(goal,slot))").unwrap();
        let digest = flow_digest("demo").unwrap();
        db.record(0, &digest, false).unwrap();
        db.record(0, &digest, false).unwrap();
        let mut adapted = goal.clone();
        db.apply(&mut adapted).unwrap();
        assert_eq!(crate::agent::plan(&adapted).unwrap(), vec![1]);
        db.record(0, &[42], true).unwrap();
        db.apply(&mut goal).unwrap();
        assert_eq!(goal.skills[0].cost, 1);
        for slot in 0..300 {
            db.record(slot, &digest, true).unwrap();
        }
        assert_eq!(
            db.db
                .query_row("SELECT count(*) FROM routes", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            LIMIT
        );
    }
}
