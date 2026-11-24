//! ReflexCore Goal Agent 0.3.0
//!
//! Deterministic, cost-aware planning over verified UIA flow skills.
//! This is not an LLM. Skills execute only through the existing Flow Engine;
//! no shell commands or unverified UI mutations are accepted.
//! Runtime reports store structural status only, never goal text or UI values.

#[path = "agent_memory.rs"]
pub(crate) mod memory;

use serde::{Deserialize, Serialize};
use std::{
    cmp::Reverse,
    collections::{BinaryHeap, HashMap, HashSet},
    error::Error,
    fs::{self, OpenOptions},
    io::Write,
    path::{Component, Path},
    time::Instant,
};

type Result<T> = std::result::Result<T, Box<dyn Error>>;

// Shared Goal Agent scoring for Citadel. The Rust bridge owns observations and
// evidence; this function never executes an action or touches Windows input.
#[derive(Clone, Copy)]
pub(crate) struct CitadelSignals {
    pub walls: usize,
    pub threats: usize,
    pub allies: usize,
    pub injured: bool,
    pub no_giants: bool,
    pub disable_defenses: bool,
}
pub(crate) fn citadel_skill_score(kind: &str, s: &CitadelSignals, previous_failures: u32) -> i32 {
    if kind == "giant" && s.no_giants { return -10000; }
    let mut score = match kind {
        "giant" => if s.threats > 0 {95} else {40},
        "archer" => 75,
        "sapper" => if s.walls > 0 {110} else {28},
        "raider" => 65,
        "medic" => if s.injured {115} else {30},
        _ => return -10000,
    };
    if s.allies == 0 && kind == "giant" { score += 50; }
    if s.allies == 0 && kind == "archer" { score += 12; }
    if s.disable_defenses && kind == "archer" { score += 30; }
    // A bounded reliability penalty is learned from VERIFIED failed readbacks,
    // not from a guessed reward or a cosmetic visual change.
    score - (previous_failures.min(6) as i32 * 12)
}

const SCHEMA: &str = "reflexcore.goal.v1";
const EVENT_DIR: &str = "data/agent/events";
const MAX_MANIFEST_BYTES: u64 = 2 * 1024 * 1024;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Goal {
    schema: String,
    name: String,
    initial_state: String,
    goal_state: String,
    skills: Vec<Skill>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Skill {
    id: String,
    from: String,
    to: String,
    flow: String,
    #[serde(default = "default_cost")]
    cost: u32,
}

fn default_cost() -> u32 {
    1
}

fn valid_id(text: &str) -> bool {
    !text.is_empty()
        && text.len() <= 80
        && text
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.'))
}

fn safe_flow_path(path: &str) -> bool {
    if path == "demo" {
        return true;
    }
    let file = Path::new(path);
    if file.is_absolute() || file.extension().and_then(|x| x.to_str()) != Some("json") {
        return false;
    }
    let mut components = file.components();
    let allowed_prefix = matches!(
        components.next(),
        Some(Component::Normal(root)) if root == "examples" || root == "tasks"
    );
    allowed_prefix
        && components.next().is_some()
        && file
            .components()
            .all(|c| matches!(c, Component::Normal(_)))
}

fn validate(goal: &Goal) -> Result<()> {
    if goal.schema != SCHEMA {
        return Err("Unsupported goal manifest schema".into());
    }
    for id in [&goal.name, &goal.initial_state, &goal.goal_state] {
        if !valid_id(id) {
            return Err("Goal or state identifier is invalid".into());
        }
    }
    if goal.skills.is_empty() || goal.skills.len() > 2048 {
        return Err("Goal requires 1..2048 skills".into());
    }
    let mut ids = HashSet::new();
    for skill in &goal.skills {
        if !valid_id(&skill.id) || !valid_id(&skill.from) || !valid_id(&skill.to) {
            return Err("Skill identifier or state is invalid".into());
        }
        if !ids.insert(&skill.id) {
            return Err("Skill identifiers must be unique".into());
        }
        if skill.from == skill.to {
            return Err("A skill must change the symbolic state".into());
        }
        if !(1..=10_000).contains(&skill.cost) {
            return Err("Skill cost must be 1..10000".into());
        }
        if !safe_flow_path(&skill.flow) {
            return Err("Skill flow must be 'demo' or an examples/tasks JSON path".into());
        }
    }
    Ok(())
}

fn parse(source: &str) -> Result<Goal> {
    let value: Goal = serde_json::from_str(source)?;
    validate(&value)?;
    Ok(value)
}

fn read_goal(path: &Path) -> Result<Goal> {
    if fs::metadata(path)?.len() > MAX_MANIFEST_BYTES {
        return Err("Goal file exceeds 2 MiB".into());
    }
    parse(&fs::read_to_string(path)?)
}

// Dijkstra with positive skill costs. The sequence number and skill names are
// stable tie-breakers so identical inputs yield identical plans.
fn plan(goal: &Goal) -> Result<Vec<usize>> {
    validate(goal)?;
    let edges: Vec<_> = goal.skills.iter().map(|s| (s.id.as_str(), s.from.as_str(), s.to.as_str(), s.cost)).collect();
    plan_edges(&goal.initial_state, &goal.goal_state, &edges)
}

pub(crate) fn plan_edges(initial: &str, target: &str, skills: &[(&str, &str, &str, u32)]) -> Result<Vec<usize>> {
    if initial == target {
        return Ok(Vec::new());
    }
    let mut best: HashMap<String, (u64, usize)> = HashMap::new();
    let mut predecessor: HashMap<String, (String, usize)> = HashMap::new();
    let mut queue: BinaryHeap<Reverse<(u64, usize, String)>> = BinaryHeap::new();
    best.insert(initial.to_owned(), (0, 0));
    queue.push(Reverse((0, 0, initial.to_owned())));

    let mut indexes: Vec<usize> = (0..skills.len()).collect();
    indexes.sort_by(|&left, &right| skills[left].0.cmp(skills[right].0));

    let mut outgoing: HashMap<&str, Vec<usize>> = HashMap::new();
    for index in indexes {
        outgoing.entry(skills[index].1).or_default().push(index);
    }
    while let Some(Reverse((cost, hops, state))) = queue.pop() {
        if best.get(&state) != Some(&(cost, hops)) {
            continue;
        }
        if state == target {
            break;
        }
        let Some(edges) = outgoing.get(state.as_str()) else { continue };
        for &index in edges {
            let (_, _, to, edge_cost) = skills[index];
            let next_cost = cost + u64::from(edge_cost);
            let next_hops = hops + 1;
            let candidate = (next_cost, next_hops);
            if best.get(to).is_none_or(|old| candidate < *old) {
                best.insert(to.to_owned(), candidate);
                predecessor.insert(to.to_owned(), (state.clone(), index));
                queue.push(Reverse((next_cost, next_hops, to.to_owned())));
            }
        }
    }
    if !best.contains_key(target) {
        return Err("No verified skill path reaches the requested goal".into());
    }
    let mut path = Vec::new();
    let mut cursor = target;
    while cursor != initial {
        let (previous, index) = predecessor
            .get(cursor)
            .ok_or("Planner predecessor chain is incomplete")?;
        path.push(*index);
        cursor = previous;
    }
    path.reverse();
    Ok(path)
}

#[derive(Serialize)]
struct Event {
    schema: &'static str,
    run_id: String,
    phase: &'static str,
    completed_skills: usize,
    total_skills: usize,
    elapsed_ms: u128,
}

fn log_event(run_id: &str, event: &Event, number: usize) -> Result<()> {
    fs::create_dir_all(EVENT_DIR)?;
    let filename = format!("{run_id}-{number:05}.json");
    let path = Path::new(EVENT_DIR).join(filename);
    let mut file = OpenOptions::new().write(true).create_new(true).open(path)?;
    file.write_all(&serde_json::to_vec_pretty(event)?)?;
    file.sync_all()?;
    Ok(())
}

fn print_status() -> Result<()> {
    let directory = Path::new(EVENT_DIR);
    if !directory.exists() {
        println!("[ReflexCore] No previous Goal Agent runs.");
        return Ok(());
    }
    let last = fs::read_dir(directory)?
        .filter_map(|item| item.ok())
        .filter(|entry| entry.path().extension().is_some_and(|s| s == "json"))
        .max_by_key(|entry| (entry.metadata().and_then(|metadata| metadata.modified()).ok(), entry.file_name()));
    if let Some(last) = last {
        println!("{}", fs::read_to_string(last.path())?);
    } else {
        println!("[ReflexCore] No previous Goal Agent runs.");
    }
    Ok(())
}

fn execute(goal: &Goal, planned: &[usize], mut memory: Option<&mut memory::Memory>, run_id: &str) -> Result<()> {
    let started = Instant::now();
    let total = planned.len();
    let mut completed = 0;
    let initial = Event {
        schema: "reflexcore.agent.event.v1",
        run_id: run_id.to_owned(),
        phase: if total == 0 { "unverified" } else { "running" },
        completed_skills: completed,
        total_skills: total,
        elapsed_ms: 0,
    };
    log_event(run_id, &initial, 0)?;

    for (step, &index) in planned.iter().enumerate() {
        let skill = &goal.skills[index];
        println!("[Agent {:02}/{}] skill={} (running verified Flow Engine)", step + 1, total, skill.id);
        let args = if skill.flow == "demo" {
            vec!["demo".to_owned(), "--execute".to_owned()]
        } else {
            vec!["run".to_owned(), skill.flow.clone(), "--execute".to_owned()]
        };
        let version = memory.as_ref().and_then(|_| memory::Memory::fingerprint(&skill.flow));
        let outcome = crate::flow::run(&args);
        let fault = outcome.as_ref().err().map(|error| error.downcast_ref::<crate::task_integrity::Fault>()
            .copied().unwrap_or(crate::task_integrity::Fault::Infrastructure));
        if let (Some(db), Some(version)) = (memory.as_deref_mut(), version) {
            if memory::Memory::fingerprint(&skill.flow).as_ref() == Some(&version)
                && matches!(fault, None | Some(crate::task_integrity::Fault::VerificationFailed))
                && db.record(index, &version, outcome.is_ok()).is_err() {
                eprintln!("[ReflexCore] Could not persist skill outcome.");
            }
        }
        if outcome.is_err() {
            let event = Event {
                schema: "reflexcore.agent.event.v1",
                run_id: run_id.to_owned(),
                phase: match fault {
                    Some(crate::task_integrity::Fault::Cancelled | crate::task_integrity::Fault::CancelledUnknown) => "cancelled",
                    Some(crate::task_integrity::Fault::EffectUnknown) => "unverified",
                    _ => "failed",
                },
                completed_skills: completed,
                total_skills: total,
                elapsed_ms: started.elapsed().as_millis(),
            };
            log_event(run_id, &event, step + 1)?;
            return outcome;
        }
        completed += 1;
        let event = Event {
            schema: "reflexcore.agent.event.v1",
            run_id: run_id.to_owned(),
            phase: if completed == total { "verified" } else { "running" },
            completed_skills: completed,
            total_skills: total,
            elapsed_ms: started.elapsed().as_millis(),
        };
        log_event(run_id, &event, step + 1)?;
    }

    if total == 0 { return Err(crate::task_integrity::Fault::EffectUnknown.into()); }
    println!("[ReflexCore] GOAL VERIFIED: {completed}/{total} skills, {} ms", started.elapsed().as_millis());
    Ok(())
}

fn print_plan(goal: &Goal, planned: &[usize]) {
    let total_cost: u64 = planned.iter().map(|&i| u64::from(goal.skills[i].cost)).sum();
    println!("[ReflexCore] Goal plan: {} skills, total cost {}", planned.len(), total_cost);
    for (index, &i) in planned.iter().enumerate() {
        let s = &goal.skills[i];
        println!("  {:02}. {}: {} -> {} [flow]", index + 1, s.id, s.from, s.to);
    }
}

pub fn run(args: &[String]) -> Result<()> {
    let Some(command) = args.first().map(String::as_str) else {
        return Err("Usage: agent plan <goal.json> | agent run <goal.json> [--execute] | agent demo [--execute] | agent status".into());
    };
    if command == "status" {
        if args.len() != 1 {
            return Err("Usage: agent status".into());
        }
        return print_status();
    }
    if command == "verified-demo" {
        if args.len() != 2 || args[1] != "--execute" {
            return Err("Usage: agent verified-demo --execute (opens an owned WinForms fixture)".into());
        }
        let run_id = crate::task_integrity::run_id();
        let result = crate::flow::verified_demo();
        let fault = result.as_ref().err().map(|error| error.downcast_ref::<crate::task_integrity::Fault>()
            .copied().unwrap_or(crate::task_integrity::Fault::Infrastructure));
        crate::task_integrity::write_receipt(&run_id, fault, result.is_ok())?;
        return result;
    }
    let (goal, execute_flag) = match command {
        "demo" => {
            if args.len() > 2 || args.get(1).is_some_and(|x| x != "--execute") {
                return Err("Usage: agent demo [--execute]".into());
            }
            (parse(include_str!("../examples/goal_agent_demo.json"))?, args.len() == 2)
        }
        "plan" | "run" => {
            if args.len() < 2 || args.len() > 3 || args.get(2).is_some_and(|x| x != "--execute") {
                return Err("Usage: agent plan <goal.json> | agent run <goal.json> [--execute]".into());
            }
            if command == "plan" && args.len() == 3 {
                return Err("agent plan is read-only; omit --execute".into());
            }
            (read_goal(Path::new(&args[1]))?, command == "run" && args.len() == 3)
        }
        _ => return Err("Unknown agent command".into()),
    };
    let mode = crate::learning::Mode::configured()?;
    let mut memory = (if mode.records() || mode.adapts() {
        memory::Memory::open(&goal, execute_flag && mode.records())
    } else {
        Ok(None)
    }).unwrap_or_else(|_| {
        eprintln!("[ReflexCore] Skill memory unavailable. Using manifest costs.");
        None
    });
    let mut adjusted = goal.clone();
    if let Some(db) = memory.as_ref().filter(|_| mode.adapts()) {
        if db.apply(&mut adjusted).is_err() {
            adjusted = goal.clone();
            eprintln!("[ReflexCore] Could not read skill history. Using manifest costs.");
        }
    }
    let planned = plan(&adjusted)?;
    print_plan(&adjusted, &planned);
    if !execute_flag {
        println!("[ReflexCore] Preview only. Append --execute to run the verified skills.");
        return Ok(());
    }
    let run_id = crate::task_integrity::run_id();
    let result = execute(&goal, &planned, memory.as_mut(), &run_id);
    let fault = result.as_ref().err().map(|error| error.downcast_ref::<crate::task_integrity::Fault>()
        .copied().unwrap_or(crate::task_integrity::Fault::Infrastructure));
    crate::task_integrity::write_receipt(&run_id, fault, result.is_ok())?;
    result
}

// Small, verified CS16 skill policy used by Unified Coordinator.
// The existing UIA/Flow planner remains unchanged. These are bounded game
// skills, not arbitrary commands or assertions of movement/completion.
pub(crate) fn plan_cs16_step(
    observed: &str,
    at_bombsite: &str,
    prior: &[String],
) -> std::result::Result<Option<&'static str>, &'static str> {
    if !matches!(at_bombsite, "yes" | "no" | "unknown") {
        return Err("Invalid bombsite state");
    }
    let action = match observed {
        "FORWARD" => "FORWARD",
        "STRAFE_LEFT" => "STRAFE_LEFT",
        "STRAFE_RIGHT" => "STRAFE_RIGHT",
        "TURN_LEFT" => "TURN_LEFT",
        "TURN_RIGHT" => "TURN_RIGHT",
        "WAIT" => return Ok(None),
        "ARRIVED" if at_bombsite == "yes" => return Ok(None),
        "ARRIVED" => return Err("ARRIVED without verified zone evidence"),
        _ => return Err("Action is not in game skill allowlist"),
    };
    // Reject four successive alternating camera turns. Do not guess a new
    // direction in place of the model without a new observation.
    if prior.len() >= 3 {
        let n = prior.len();
        let a = &prior[n - 3];
        let b = &prior[n - 2];
        let c = &prior[n - 1];
        if a == c && b == action &&
            ((a == "TURN_LEFT" && b == "TURN_RIGHT") ||
             (a == "TURN_RIGHT" && b == "TURN_LEFT")) {
            return Err("Four alternating turns detected");
        }
    }
    Ok(Some(action))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> Goal {
        parse(include_str!("../examples/goal_agent_demo.json")).unwrap()
    }

    fn skill(id: &str, from: &str, to: &str, cost: u32) -> Skill {
        Skill {
            id: id.into(),
            from: from.into(),
            to: to.into(),
            flow: "demo".into(),
            cost,
        }
    }

    #[test]
    fn demo_manifest_parses() {
        assert_eq!(plan(&fixture()).unwrap().len(), 1);
    }

    #[test]
    fn chooses_cheaper_multi_step_plan() {
        let mut goal = fixture();
        goal.skills = vec![
            skill("expensive", "idle", "verified", 20),
            skill("first", "idle", "ready", 2),
            skill("second", "ready", "verified", 3),
        ];
        let selected = plan(&goal).unwrap();
        assert_eq!(selected.len(), 2);
        assert_eq!(goal.skills[selected[0]].id, "first");
        assert_eq!(goal.skills[selected[1]].id, "second");
    }

    #[test]
    fn cycles_do_not_loop() {
        let mut goal = fixture();
        goal.skills = vec![
            skill("a", "idle", "ready", 1),
            skill("b", "ready", "idle", 1),
            skill("c", "ready", "verified", 1),
        ];
        assert_eq!(plan(&goal).unwrap().len(), 2);
    }

    #[test]
    fn unknown_goal_is_rejected() {
        let mut goal = fixture();
        goal.goal_state = "never_reached".into();
        assert!(plan(&goal).is_err());
    }

    #[test]
    fn duplicate_skills_rejected() {
        let mut goal = fixture();
        goal.skills.push(goal.skills[0].clone());
        assert!(validate(&goal).is_err());
    }

    #[test]
    fn shell_paths_rejected() {
        for path in ["../outside.json", "tasks/do.ps1", "C:/tmp/a.json", "data/secrets.json", "examples/../secret.json"] {
            assert!(!safe_flow_path(path), "{path}");
        }
    }

    #[test]
    fn json_flow_paths_allowed() {
        assert!(safe_flow_path("examples/smoke_flow.json"));
        assert!(safe_flow_path("tasks/flows/my_task.json"));
    }

    #[test]
    fn zero_cost_rejected() {
        let mut goal = fixture();
        goal.skills[0].cost = 0;
        assert!(validate(&goal).is_err());
    }

    #[test]
    fn same_state_goal_needs_no_skills() {
        let mut goal = fixture();
        goal.goal_state = goal.initial_state.clone();
        assert!(plan(&goal).unwrap().is_empty());
    }

    #[test]
    fn bad_schema_rejected() {
        let mut goal = fixture();
        goal.schema = "other".into();
        assert!(validate(&goal).is_err());
    }

    #[test]
    fn unknown_manifest_properties_rejected() {
        let src = r#"{"schema":"reflexcore.goal.v1","name":"x","initial_state":"a","goal_state":"b","skills":[],"command":"powershell"}"#;
        assert!(parse(src).is_err());
    }

    #[test]
    fn event_records_no_skill_names_or_values() {
        let event = Event {
            schema: "reflexcore.agent.event.v1",
            run_id: "test".into(),
            phase: "verified",
            completed_skills: 1,
            total_skills: 1,
            elapsed_ms: 100,
        };
        let text = serde_json::to_string(&event).unwrap();
        assert!(!text.contains("private@example.com"));
        assert!(!text.contains("secret"));
        assert!(!text.contains("fixture-verify"));
    }

    #[test]
    fn state_tiebreak_uses_fewer_hops() {
        let mut goal = fixture();
        goal.skills = vec![
            skill("cheap2", "a", "verified", 1),
            skill("cheap1", "idle", "a", 1),
            skill("direct", "idle", "verified", 2),
        ];
        let chosen = plan(&goal).unwrap();
        assert_eq!(chosen.len(), 1);
    }
}
