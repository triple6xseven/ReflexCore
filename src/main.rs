#[cfg(windows)]
mod observer;
#[cfg(windows)]
mod window_diff;
#[cfg(windows)]
mod uia_explorer;
#[cfg(windows)]
mod uia_actions;
#[cfg(windows)]
mod privacy;
#[cfg(windows)]
mod flow;
#[cfg(windows)]
mod agent;
#[cfg(windows)]
mod task_control;
#[cfg(windows)]
mod unified;
#[cfg(windows)]
mod citadel_bridge;
#[cfg(windows)]
mod cs16;
#[cfg(windows)]
mod cs16_benchmark;
#[cfg(windows)]
mod cs16_demo;
#[cfg(windows)]
mod cs16_probe;
#[cfg(windows)]
mod cs16_practice;
#[cfg(windows)]
mod cs16_route;
#[cfg(windows)]
mod vision;

use serde::{Deserialize, Serialize};
use serde_json::json;

use std::{
    env,
    error::Error,
    fs::{self, OpenOptions},
    io::Write,
    path::Path,
    time::{Instant, SystemTime, UNIX_EPOCH},
};

type Result<T> = std::result::Result<T, Box<dyn Error>>;

const DATA_DIR: &str = "data";
const STATE_FILE: &str = "data/state.json";
const EVENT_FILE: &str = "data/events.jsonl";

// ==========================================
// CORE TYPES
// ==========================================

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum ThinkingMode {
    Reflex,
    Focused,
    Deep,
    Auto,
}

impl ThinkingMode {
    fn parse(value: &str) -> Option<Self> {
        match value.to_lowercase().as_str() {
            "reflex" => Some(Self::Reflex),
            "focused" => Some(Self::Focused),
            "deep" => Some(Self::Deep),
            "auto" => Some(Self::Auto),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum WorldState {
    Desktop,
    AppOpen,
    SettingsOpen,
    DarkEnabled,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum GoalKind {
    DarkTheme,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Task {
    id: u128,
    description: String,
    kind: GoalKind,
    steps: u32,
    completed: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct EngineState {
    mode: ThinkingMode,
    world: WorldState,
    task: Option<Task>,
}

impl Default for EngineState {
    fn default() -> Self {
        Self {
            mode: ThinkingMode::Auto,
            world: WorldState::Desktop,
            task: None,
        }
    }
}

// ==========================================
// REFLEX SKILL ENGINE
// ==========================================

#[derive(Debug, Clone, Copy)]
struct Skill {
    name: &'static str,
    goal: GoalKind,
    precondition: WorldState,
    postcondition: WorldState,
}

// Deterministic demo skill library.
//
// Future versions will load verified skills
// from persistent storage and perform real
// Windows actions through an executor.

const SKILLS: &[Skill] = &[
    Skill {
        name: "open_application",
        goal: GoalKind::DarkTheme,
        precondition: WorldState::Desktop,
        postcondition: WorldState::AppOpen,
    },
    Skill {
        name: "open_settings",
        goal: GoalKind::DarkTheme,
        precondition: WorldState::AppOpen,
        postcondition: WorldState::SettingsOpen,
    },
    Skill {
        name: "enable_dark_theme",
        goal: GoalKind::DarkTheme,
        precondition: WorldState::SettingsOpen,
        postcondition: WorldState::DarkEnabled,
    },
];

fn find_skill(
    goal: GoalKind,
    world: WorldState,
) -> Option<&'static Skill> {
    SKILLS.iter().find(|skill| {
        skill.goal == goal
            && skill.precondition == world
    })
}

fn execute_step(state: &mut EngineState) -> Result<&'static str> {
    let task = state
        .task
        .as_mut()
        .ok_or("No active task")?;

    if task.completed {
        return Err("Task already completed".into());
    }

    let skill = find_skill(task.kind, state.world)
        .ok_or("No applicable skill for current state")?;

    // MOCK EXECUTOR:
    // Simulates a deterministic world transition.
    // Does not control actual Windows applications.
    state.world = skill.postcondition;

    task.steps += 1;

    // Demo verifier checks the simulated state.
    task.completed = state.world == WorldState::DarkEnabled;

    Ok(skill.name)
}

// ==========================================
// PERSISTENT MEMORY
// ==========================================

fn load_state() -> Result<EngineState> {
    if !Path::new(STATE_FILE).exists() {
        return Ok(EngineState::default());
    }

    let bytes = fs::read(STATE_FILE)?;
    let state = serde_json::from_slice(&bytes)?;

    Ok(state)
}

fn save_state(state: &EngineState) -> Result<()> {
    fs::create_dir_all(DATA_DIR)?;

    let temporary = "data/state.json.tmp";
    let encoded = serde_json::to_vec_pretty(state)?;

    fs::write(temporary, encoded)?;
    fs::rename(temporary, STATE_FILE)?;

    Ok(())
}

fn now_ms() -> Result<u128> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)?
        .as_millis())
}

fn log_event(
    state: &EngineState,
    event: &str,
    duration_us: Option<u128>,
) -> Result<()> {
    fs::create_dir_all(DATA_DIR)?;

    let record = json!({
        "timestamp_ms": now_ms()?,
        "event": event,
        "task_id": state.task.as_ref().map(|t| t.id),
        "step": state.task.as_ref().map(|t| t.steps),
        "world": state.world,
        "mode": state.mode,
        "duration_us": duration_us,
    });

    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(EVENT_FILE)?;

    writeln!(file, "{}", record)?;

    Ok(())
}

// ==========================================
// TASK CONTROL
// ==========================================

fn detect_goal(description: &str) -> Option<GoalKind> {
    let text = description.to_lowercase();

    // Temporary deterministic parser.
    // Not a language model.
    if text.contains("dark")
        || text.contains("темн")
        || text.contains("тёмн")
    {
        Some(GoalKind::DarkTheme)
    } else {
        None
    }
}

fn new_task(
    state: &mut EngineState,
    description: String,
) -> Result<()> {
    if state.task.as_ref().is_some_and(|t| !t.completed) {
        return Err(
            "Active task exists. Finish it or use reset.".into()
        );
    }

    let goal = detect_goal(&description)
        .ok_or("Unsupported demo goal. Try: dark-theme")?;

    let task = Task {
        id: now_ms()?,
        description,
        kind: goal,
        steps: 0,
        completed: false,
    };

    state.world = WorldState::Desktop;
    state.task = Some(task);

    save_state(state)?;
    log_event(state, "task_created", None)?;

    println!("Task created successfully.");

    Ok(())
}

fn run_step(state: &mut EngineState) -> Result<()> {
    let start = Instant::now();

    let action = execute_step(state)?;

    let duration = start.elapsed().as_micros();

    // Persist progress before reporting success.
    save_state(state)?;
    log_event(state, action, Some(duration))?;

    println!(
        "ACTION: {} | state: {:?} | {} us",
        action, state.world, duration
    );

    if state.task.as_ref().is_some_and(|t| t.completed) {
        println!("TASK COMPLETE");
    }

    Ok(())
}

fn run_task(state: &mut EngineState) -> Result<()> {
    const MAX_STEPS: usize = 10;

    for _ in 0..MAX_STEPS {
        let finished = state
            .task
            .as_ref()
            .ok_or("No active task")?
            .completed;

        if finished {
            break;
        }

        run_step(state)?;
    }

    Ok(())
}

fn print_help() {
    println!(
        r#"
REFLEXCORE 0.0.1

COMMANDS:

  new <goal>       Create demo task
  step             Execute one step
  run              Execute remaining steps
  status           Print persistent state as JSON
  skills           List registered skills
  mode <name>      reflex | focused | deep | auto
  reset            Reset task and simulated world
  diff             Compare windows with saved snapshot
  uia [title]      Explore Windows UI Automation tree
  act <window>     Inspect / act on a UI element (dry-run by default)
  flow <command>   Validate/run local UI automation scenarios
  agent <command>  Plan and run verified goal skills
  unified <command>  Bounded CS16 goal coordinator (no SendInput)
  cs16 <command>   Inspect Counter-Strike 1.6 telemetry and benchmark offline rounds
  citadel-bridge serve  JSONL Rust Goal Agent for Citadel
  help             Show commands

EXAMPLE:

  reflexcore new "Enable dark mode"
  reflexcore step
  reflexcore run
  reflexcore status

Current limitations:
  - Simulated desktop environment
  - No local AI model yet
  - No real Windows automation yet
"#
    );
}

// ==========================================
// ENTRY POINT
// ==========================================

fn main() -> Result<()> {
    let args: Vec<String> = env::args().skip(1).collect();

    let command = args
        .first()
        .map(String::as_str)
        .unwrap_or("help");

    // Unified game coordination is a bounded, versioned CLI/stdio IPC.
    // It does not need access to the legacy demo state file.
    #[cfg(windows)]
    if command == "unified" {
        return unified::run(&args[1..]);
    }

    #[cfg(windows)]
    if command == "citadel-bridge" {
        return citadel_bridge::run(&args[1..]);
    }

    #[cfg(windows)]
    if command == "cs16" {
        return cs16::run(&args[1..]);
    }

    // Do not read potentially broken demo state for independent tools or help.
    let mut state = if matches!(command,"new"|"step"|"run"|"status"|"skills"|"mode"|"reset") {
        load_state()?
    } else {EngineState::default()};

    match command {
        #[cfg(windows)]
        "agent" => {
            agent::run(&args[1..])?;
        }

        #[cfg(windows)]
        "flow" => {
            flow::run(&args[1..])?;
        }

        #[cfg(windows)]
        "act" => {
            uia_actions::run(&args[1..])?;
        }

        #[cfg(windows)]
        "uia-act-worker" => {
            uia_actions::run_worker(&args[1..])?;
        }

        #[cfg(windows)]
        "uia" => {
            uia_explorer::run(&args[1..])?;
        }

        #[cfg(windows)]
        "uia-worker" => {
            uia_explorer::run_worker(&args[1..])?;
        }

        #[cfg(windows)]
        "diff" => {
            window_diff::run()?;
        }
        #[cfg(windows)]
        "windows" => {
            observer::show(None, false)?;
        }

        #[cfg(windows)]
        "find-window" => {
            let query = args.iter().skip(1).cloned().collect::<Vec<_>>().join(" ");
            if query.trim().is_empty() {
                return Err("Specify a window title".into());
            }
            observer::show(Some(&query), false)?;
        }

        #[cfg(windows)]
        "snapshot" => {
            observer::show(None, true)?;
        }
        "new" => {
            let description = args
                .iter()
                .skip(1)
                .cloned()
                .collect::<Vec<_>>()
                .join(" ");

            new_task(&mut state, description)?;
        }

        "step" => {
            run_step(&mut state)?;
        }

        "run" => {
            run_task(&mut state)?;
        }

        "status" => {
            println!(
                "{}",
                serde_json::to_string_pretty(&state)?
            );
        }

        "skills" => {
            for skill in SKILLS {
                println!(
                    "{} | {:?} -> {:?}",
                    skill.name,
                    skill.precondition,
                    skill.postcondition
                );
            }
        }

        "mode" => {
            let name = args
                .get(1)
                .ok_or("Specify a thinking mode")?;

            state.mode = ThinkingMode::parse(name)
                .ok_or("Invalid thinking mode")?;

            save_state(&state)?;
            log_event(&state, "thinking_mode_changed", None)?;

            println!("Mode: {:?}", state.mode);
        }

        "reset" => {
            state = EngineState::default();

            save_state(&state)?;
            log_event(&state, "reset", None)?;

            println!("State reset.");
        }

        "help" | "--help" => print_help(),

        _ => {
            print_help();
            return Err("Unknown command".into());
        }
    }

    Ok(())
}

// ==========================================
// AUTOMATED TESTS
// ==========================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn skill_lookup_respects_world_state() {
        let skill =
            find_skill(GoalKind::DarkTheme, WorldState::AppOpen)
                .unwrap();

        assert_eq!(skill.name, "open_settings");
    }

    #[test]
    fn task_completes_in_three_steps() {
        let mut state = EngineState::default();

        state.task = Some(Task {
            id: 1,
            description: "Enable dark theme".into(),
            kind: GoalKind::DarkTheme,
            steps: 0,
            completed: false,
        });

        for _ in 0..3 {
            execute_step(&mut state).unwrap();
        }

        assert_eq!(state.world, WorldState::DarkEnabled);
        assert!(state.task.unwrap().completed);
    }

    #[test]
    fn state_survives_serialization() {
        let state = EngineState::default();

        let encoded = serde_json::to_string(&state).unwrap();

        let restored: EngineState =
            serde_json::from_str(&encoded).unwrap();

        assert_eq!(restored.world, WorldState::Desktop);
    }
}
