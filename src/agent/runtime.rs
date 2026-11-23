use super::{memory, Goal, Result};
use crate::task_control::{Cancellation, Cancelled};
use serde::Serialize;
use std::{
    error::Error,
    fmt,
    fs::{self, OpenOptions},
    io::Write,
    path::Path,
    time::{Instant, SystemTime, UNIX_EPOCH},
};

const EVENT_DIR: &str = "data/agent/events";

#[derive(Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
enum Phase {
    Running,
    Verified,
    Failed,
    Cancelled,
}

#[derive(Debug)]
pub(super) enum TaskError {
    Journal(Box<dyn Error>),
    SkillFailed { step: usize },
    Cancelled(Cancelled),
}

impl fmt::Display for TaskError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Journal(err) => write!(f, "Goal event could not be written: {err}"),
            Self::SkillFailed { step } => {
                write!(f, "Agent stopped: skill {step} failed verification")
            }
            Self::Cancelled(err) => err.fmt(f),
        }
    }
}

impl Error for TaskError {}

#[derive(Serialize)]
struct Event {
    schema: &'static str,
    run_id: String,
    phase: Phase,
    completed_skills: usize,
    total_skills: usize,
    elapsed_ms: u128,
}

fn now_ns() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos())
}

fn log_event(run_id: &str, event: &Event, number: usize) -> Result<()> {
    fs::create_dir_all(EVENT_DIR)?;
    let filename = format!("{run_id}-{number:05}.json");
    let path = Path::new(EVENT_DIR).join(filename);
    let temporary = path.with_extension("pending");
    {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)?;
        file.write_all(&serde_json::to_vec_pretty(event)?)?;
        file.sync_all()?;
    }
    fs::rename(temporary, path)?;
    Ok(())
}

pub(super) fn print_status() -> Result<()> {
    let directory = Path::new(EVENT_DIR);
    if !directory.exists() {
        println!("[ReflexCore] No previous Goal Agent runs.");
        return Ok(());
    }
    let last = fs::read_dir(directory)?
        .filter_map(|item| item.ok())
        .filter(|entry| entry.path().extension().is_some_and(|s| s == "json"))
        .max_by_key(|entry| entry.file_name());
    if let Some(last) = last {
        println!("{}", fs::read_to_string(last.path())?);
    } else {
        println!("[ReflexCore] No previous Goal Agent runs.");
    }
    Ok(())
}

pub(super) fn execute(
    goal: &Goal,
    planned: &[usize],
    mut memory: Option<&mut memory::Memory>,
) -> std::result::Result<(), TaskError> {
    let started = Instant::now();
    let stop = Cancellation::from_queue();
    let mut event = Event {
        schema: "reflexcore.agent.event.v1",
        run_id: format!("{:020}-{}", now_ns(), std::process::id()),
        phase: if stop.check().is_err() {
            Phase::Cancelled
        } else if planned.is_empty() {
            Phase::Verified
        } else {
            Phase::Running
        },
        completed_skills: 0,
        total_skills: planned.len(),
        elapsed_ms: 0,
    };
    log_event(&event.run_id, &event, 0).map_err(TaskError::Journal)?;
    if matches!(event.phase, Phase::Cancelled) {
        return Err(TaskError::Cancelled(Cancelled));
    }

    for (step, &index) in planned.iter().enumerate() {
        let skill = &goal.skills[index];
        let result = stop
            .check()
            .map_err(|err| Box::new(err) as Box<dyn Error>)
            .and_then(|()| {
                println!(
                    "[Agent {:02}/{}] skill={} (running verified Flow Engine)",
                    step + 1,
                    planned.len(),
                    skill.id
                );
                let version = memory
                    .as_ref()
                    .and_then(|_| memory::Memory::fingerprint(&skill.flow));
                let result = crate::flow::execute_skill(&skill.flow, &stop);
                if !matches!(&result, Err(err) if err.is::<Cancelled>()) {
                    if let (Some(db), Some(version)) = (memory.as_deref_mut(), version) {
                        if memory::Memory::fingerprint(&skill.flow).as_ref() == Some(&version)
                            && db.record(index, &version, result.is_ok()).is_err()
                        {
                            eprintln!("[ReflexCore] Could not persist skill outcome.");
                        }
                    }
                }
                result
            });
        let error = match result {
            Ok(()) => {
                event.completed_skills += 1;
                event.phase = if event.completed_skills == event.total_skills {
                    Phase::Verified
                } else {
                    Phase::Running
                };
                None
            }
            Err(err) if err.is::<Cancelled>() => {
                event.phase = Phase::Cancelled;
                Some(TaskError::Cancelled(Cancelled))
            }
            Err(_) => {
                event.phase = Phase::Failed;
                Some(TaskError::SkillFailed { step: step + 1 })
            }
        };
        event.elapsed_ms = started.elapsed().as_millis();
        log_event(&event.run_id, &event, step + 1).map_err(TaskError::Journal)?;
        if let Some(error) = error {
            return Err(error);
        }
    }

    println!(
        "[ReflexCore] GOAL VERIFIED: {}/{} skills, {} ms",
        event.completed_skills,
        event.total_skills,
        started.elapsed().as_millis()
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn event_records_no_skill_names_or_values() {
        let event = Event {
            schema: "reflexcore.agent.event.v1",
            run_id: "test".into(),
            phase: Phase::Verified,
            completed_skills: 1,
            total_skills: 1,
            elapsed_ms: 100,
        };
        let text = serde_json::to_string(&event).unwrap();
        assert!(!text.contains("private@example.com"));
        assert!(!text.contains("secret"));
        assert!(!text.contains("fixture-verify"));
    }
}
