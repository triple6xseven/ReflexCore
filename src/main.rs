#[cfg(windows)]
mod dev_context;
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
mod task_integrity;
#[cfg(windows)]
mod agent;
#[cfg(windows)]
mod learning;
#[cfg(windows)]
mod neural_runtime;
#[cfg(windows)]
mod skill_registry;
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

#[cfg(windows)]
mod handoff;
#[cfg(windows)]
mod local_files;
mod legacy_demo;

use std::env;

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

fn print_help() {
    #[cfg(windows)]
    println!("learning registry | learning models | learning experiment | learning validate <checkpoint-id>");
    #[cfg(windows)]
    println!("learning bind <skill-id> <version> <winforms|notepad> <foreground|background>");
    println!(
        r#"
REFLEXCORE

COMMANDS:

  legacy-demo <command>  Run the legacy desktop simulator

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
  handoff <folder> <checklist.json> <new-report.json>  Verify a handoff folder
  unified <command>  Bounded CS16 goal coordinator (no SendInput)
  cs16 <command>   Inspect Counter-Strike 1.6 telemetry and benchmark offline rounds
  citadel-bridge serve  JSONL Rust Goal Agent for Citadel
  help             Show commands

EXAMPLE:

  reflexcore new "Enable dark mode"
  reflexcore step
  reflexcore run
  reflexcore status

The new, step, run, status, skills, mode and reset commands are legacy-demo aliases.
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

    #[cfg(windows)]
    if command == "dev-context" { return dev_context::run(&args[1..]); }
    #[cfg(windows)]
    if command == "handoff" { return handoff::run(&args[1..]); }
    #[cfg(windows)]
    if command == "learning" {
        return learning::run(&args[1..]);
    }

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

    if command == "legacy-demo" {
        return legacy_demo::run(&args[1..]);
    }
    if matches!(command, "new" | "step" | "run" | "status" | "skills" | "mode" | "reset") {
        return legacy_demo::run(&args);
    }

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
        "uia-session-worker" => uia_actions::session::worker(&args[1..])?,

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
        "help" | "--help" => print_help(),

        _ => {
            print_help();
            return Err("Unknown command".into());
        }
    }

    Ok(())
}
