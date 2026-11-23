//! ReflexCore 0.1.0: deterministic Observe -> Act -> Verify flow runner.
//! The existing UIA action worker is the only actuator; the flow engine never
//! clicks coordinates or executes arbitrary plan-supplied shell commands.
//! This module intentionally saves no UI labels, selectors, text, or values.

use crate::task_control::{Cancellation, Cancelled};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    error::Error,
    fs,
    path::Path,
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

type Result<T> = std::result::Result<T, Box<dyn Error>>;
const REPORT: &str = "data/flow_last_run.json";
const ACTION_REPORT: &str = "data/uia_last_action.json";
const SCHEMA: &str = "reflexcore.flow.v1";

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct Flow {
    schema: String,
    name: String,
    window: String,
    steps: Vec<Step>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct Step {
    action: String,
    #[serde(default)]
    window: Option<String>,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    path: Option<String>,
    #[serde(default, rename = "type")]
    kind: Option<String>,
    #[serde(default)]
    value: Option<String>,
    #[serde(default)]
    retries: Option<u8>,
    #[serde(default)]
    timeout_ms: Option<u64>,
    #[serde(default)]
    max_nodes: Option<usize>,
}

#[derive(Debug, Serialize)]
struct StepReport {
    index: usize,
    action: String,
    attempts: usize,
    status: String,
    verification: String,
    duration_ms: u128,
}

#[derive(Debug, Serialize)]
struct FlowReport {
    schema: &'static str,
    started_ms: u128,
    duration_ms: u128,
    outcome: &'static str,
    completed_steps: usize,
    total_steps: usize,
    steps: Vec<StepReport>,
}

fn now_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis())
}

fn is_assertion(action: &str) -> bool {
    matches!(action, "assert-name" | "assert-value")
}

fn is_mutation(action: &str) -> bool {
    matches!(action, "focus" | "invoke" | "toggle" | "select" | "set-value")
}

fn retry_safe(action: &str) -> bool {
    matches!(action, "inspect" | "assert-name" | "assert-value" | "focus" | "set-value")
}

fn validate(flow: &Flow) -> Result<()> {
    if flow.schema != SCHEMA {
        return Err(format!("Expected schema {SCHEMA}").into());
    }
    if flow.name.trim().is_empty() || flow.window.trim().is_empty() {
        return Err("Flow name/window must not be empty".into());
    }
    if flow.steps.is_empty() {
        return Err("Flow has no steps".into());
    }
    for (idx, step) in flow.steps.iter().enumerate() {
        if !matches!(step.action.as_str(),
            "inspect" | "focus" | "invoke" | "toggle" | "select" |
            "set-value" | "assert-value" | "assert-name") {
            return Err(format!("Step {}: unsupported action", idx + 1).into());
        }
        if step.name.is_none() && step.id.is_none() && step.path.is_none() {
            return Err(format!("Step {}: requires name, id, or path", idx + 1).into());
        }
        if step.window.as_deref().is_some_and(|v| v.trim().is_empty()) {
            return Err(format!("Step {}: empty window override", idx + 1).into());
        }
        if let Some(path) = &step.path {
            let mut parts = path.split('/');
            if parts.next() != Some("0") || !parts.all(|s| !s.is_empty() && s.parse::<usize>().is_ok()) {
                return Err(format!("Step {}: invalid UIA path", idx + 1).into());
            }
        }
        if matches!(step.action.as_str(), "set-value" | "assert-value" | "assert-name") != step.value.is_some() {
            return Err(format!("Step {}: expected value is missing or not applicable", idx + 1).into());
        }
        if step.retries.is_some_and(|v| v > 5) {
            return Err(format!("Step {}: retries must be <= 5", idx + 1).into());
        }
        if step.timeout_ms.is_some_and(|v| !(100..=300_000).contains(&v)) {
            return Err(format!("Step {}: timeout_ms must be 100..300000", idx + 1).into());
        }
    }
    Ok(())
}

fn parse_flow(data: &str) -> Result<Flow> {
    let flow: Flow = serde_json::from_str(data)?;
    validate(&flow)?;
    Ok(flow)
}

fn build_action_args(flow: &Flow, step: &Step) -> Vec<String> {
    let mut args = vec!["act".to_owned(), step.window.clone().unwrap_or_else(|| flow.window.clone())];
    if let Some(v) = &step.name { args.push(format!("--name={v}")); }
    if let Some(v) = &step.id { args.push(format!("--id={v}")); }
    if let Some(v) = &step.path { args.push(format!("--path={v}")); }
    if let Some(v) = &step.kind { args.push(format!("--type={v}")); }
    if let Some(v) = &step.value { args.push(format!("--value={v}")); }
    args.push(format!("--action={}", step.action));
    args.push(format!("--timeout-ms={}", step.timeout_ms.unwrap_or(10_000)));
    args.push(format!("--max-nodes={}", step.max_nodes.unwrap_or(0)));
    if is_mutation(&step.action) { args.push("--execute".to_owned()); }
    args
}

// Windows named mutex automatically releases after a crash/kill.
// The kernel object is local to the interactive logon session.
#[link(name="kernel32")]
unsafe extern "system" {
    fn CreateMutexW(attributes:*const std::ffi::c_void, initial_owner:i32, name:*const u16) -> *mut std::ffi::c_void;
    fn GetLastError() -> u32;
    fn CloseHandle(handle:*mut std::ffi::c_void) -> i32;
}
struct FlowLock(*mut std::ffi::c_void);
impl FlowLock {
    fn acquire() -> Result<Self> {
        let name:Vec<u16>="Local\\ReflexCoreFlowLockV053".encode_utf16().chain(std::iter::once(0)).collect();
        let handle=unsafe{CreateMutexW(std::ptr::null(),0,name.as_ptr())};
        if handle.is_null() {return Err("Cannot create flow mutex".into());}
        if unsafe{GetLastError()}==183 {
            unsafe{CloseHandle(handle);}
            return Err("Another flow is active".into());
        }
        Ok(Self(handle))
    }
}
impl Drop for FlowLock {fn drop(&mut self){unsafe{CloseHandle(self.0);}}}

fn execute_action(args: &[String], stop: &Cancellation) -> Result<Value> {
    stop.check()?;
    if Path::new(ACTION_REPORT).exists() {
        fs::remove_file(ACTION_REPORT)?;
    }
    let mut worker = OwnedChild(Command::new(std::env::current_exe()?)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?);
    let exit = if matches!(stop, Cancellation::Unscoped) {
        worker.0.wait()?
    } else {
        loop {
            stop.check()?;
            if let Some(status) = worker.0.try_wait()? {
                break status;
            }
            thread::sleep(Duration::from_millis(25));
        }
    };
    stop.check()?;
    if !exit.success() {
        return Err("UIA action subprocess returned a nonzero exit code".into());
    }
    let bytes = fs::read(ACTION_REPORT)
        .map_err(|_| "UIA action finished without a report")?;
    Ok(serde_json::from_slice(&bytes)?)
}

fn save_report(report: &FlowReport) -> Result<()> {
    fs::create_dir_all("data")?;
    fs::write(REPORT, serde_json::to_vec_pretty(report)?)?;
    Ok(())
}

pub(super) fn has_terminal_assertion(bytes: &[u8]) -> bool {
    std::str::from_utf8(bytes).ok()
        .and_then(|source| parse_flow(source).ok())
        .and_then(|flow| flow.steps.last().map(|step| is_assertion(&step.action)))
        .unwrap_or(false)
}

fn execute_flow(flow: &Flow, stop: &Cancellation) -> Result<()> {
    validate(flow)?;
    let _lock = FlowLock::acquire()?;
    let started = Instant::now();
    let mut final_report = FlowReport {
        schema: "reflexcore.flow.execution.v1",
        started_ms: now_ms(),
        duration_ms: 0,
        outcome: "failed",
        completed_steps: 0,
        total_steps: flow.steps.len(),
        steps: Vec::new(),
    };
    let mut unresolved_effect = false;
    for (index, step) in flow.steps.iter().enumerate() {
        let per_step = Instant::now();
        let mut last_status = "worker_error".to_owned();
        let mut last_verification = "not_applicable".to_owned();
        let attempts_allowed = if retry_safe(&step.action) {
            usize::from(step.retries.unwrap_or(2)) + 1
        } else {
            1 // Never blindly retry an invoke/toggle/select; it may already have happened.
        };
        let mut attempt_count = 0;
        let mut succeeded = false;
        for attempt in 1..=attempts_allowed {
            attempt_count = attempt;
            match execute_action(&build_action_args(flow, step), stop) {
                Ok(response) => {
                    last_status = response["status"].as_str().unwrap_or("invalid_report").to_owned();
                    last_verification = response["verification"].as_str().unwrap_or("not_applicable").to_owned();
                    succeeded = match step.action.as_str() {
                        "inspect" => last_status == "inspected",
                        "assert-name" | "assert-value" =>
                            last_status == "assertion_passed" && last_verification == "verified",
                        _ => last_status == "issued",
                    };
                }
                Err(err) if err.is::<Cancelled>() => {
                    final_report.outcome = "cancelled";
                    final_report.duration_ms = started.elapsed().as_millis();
                    if let Err(report_error) = save_report(&final_report) {
                        eprintln!("[ReflexCore] Could not save cancelled flow report: {report_error}");
                    }
                    return Err(err);
                }
                Err(_) => {
                    last_status = "worker_error".to_owned();
                    last_verification = "unknown".to_owned();
                }
            }
            if succeeded { break; }
            if attempt < attempts_allowed && last_status != "ambiguous" {
                thread::sleep(Duration::from_millis(250));
            } else { break; }
        }
        if succeeded {
            if is_assertion(&step.action) {
                unresolved_effect = false;
            } else if is_mutation(&step.action) && last_verification != "verified" {
                unresolved_effect = true;
            }
        }
        final_report.steps.push(StepReport {
            index: index + 1,
            action: step.action.clone(),
            attempts: attempt_count,
            status: last_status.clone(),
            verification: last_verification.clone(),
            duration_ms: per_step.elapsed().as_millis(),
        });
        println!("[{:02}/{}] {:<13} status={} verification={} tries={}",
            index + 1, flow.steps.len(), step.action, last_status, last_verification, attempt_count);
        if !succeeded {
            final_report.duration_ms = started.elapsed().as_millis();
            save_report(&final_report)?;
            return Err(format!("Flow stopped at step {} ({})", index + 1, last_status).into());
        }
        final_report.completed_steps += 1;
    }
    final_report.duration_ms = started.elapsed().as_millis();
    if unresolved_effect {
        final_report.outcome = "completed_unverified";
        save_report(&final_report)?;
        return Err("Flow actions ran, but their final effect was not independently verified".into());
    }
    final_report.outcome = "passed";
    save_report(&final_report)?;
    println!("[ReflexCore] FLOW PASSED: {} steps, {} ms", flow.steps.len(), final_report.duration_ms);
    println!("[Privacy] Redacted execution report: {REPORT}");
    Ok(())
}

fn fixture_visible() -> bool {
    crate::observer::capture_value()
        .ok()
        .and_then(|v| v["windows"].as_array().cloned())
        .is_some_and(|list| list.iter().any(|w| w["title"].as_str() == Some("ReflexCore Test Window")))
}

struct OwnedChild(Child);
impl Drop for OwnedChild {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn demo(execute: bool, stop: &Cancellation) -> Result<()> {
    let flow = parse_flow(include_str!("../examples/smoke_flow.json"))?;
    if !execute {
        println!("[ReflexCore] Demo has {} steps; no changes made.", flow.steps.len());
        println!("[ReflexCore] To run against a temporary test window: flow demo --execute");
        return Ok(());
    }
    stop.check()?;
    if fixture_visible() {
        return Err("A ReflexCore Test Window already exists; close it before demo".into());
    }
    let path = Path::new("tools/ReflexCore-Fixture.ps1");
    if !path.is_file() {
        return Err("Missing test fixture: tools/ReflexCore-Fixture.ps1".into());
    }
    let child = Command::new("powershell.exe")
        .args(["-NoProfile", "-Sta", "-NonInteractive", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File"])
        .arg(path)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;
    let mut fixture = OwnedChild(child);
    let started = Instant::now();
    while !fixture_visible() {
        stop.check()?;
        if fixture.0.try_wait()?.is_some() {
            return Err("Windows Forms test fixture exited before opening".into());
        }
        if started.elapsed() > Duration::from_secs(10) {
            return Err("Test fixture did not open within 10 seconds".into());
        }
        thread::sleep(Duration::from_millis(150));
    }
    println!("[ReflexCore] Test fixture launched; running full UIA flow...");
    execute_flow(&flow, stop)
}

pub(crate) fn execute_skill(source: &str, stop: &Cancellation) -> Result<()> {
    stop.check()?;
    if source == "demo" {
        return demo(true, stop);
    }
    let flow = parse_flow(&fs::read_to_string(source)?)?;
    execute_flow(&flow, stop)
}

pub fn run(args: &[String]) -> Result<()> {
    let Some(command) = args.first().map(String::as_str) else {
        return Err("Usage: flow validate <file> | flow run <file> [--execute] | flow demo [--execute]".into());
    };
    match command {
        "demo" => {
            let execute = args.get(1).is_some_and(|s| s == "--execute");
            if args.len() > (if execute { 2 } else { 1 }) {
                return Err("Usage: flow demo [--execute]".into());
            }
            demo(execute, &Cancellation::from_queue())
        }
        "validate" | "run" => {
            let path = args.get(1).ok_or("Expected a JSON flow path")?;
            let execute = args.get(2).is_some_and(|s| s == "--execute");
            if args.len() > (if execute { 3 } else { 2 }) {
                return Err("Usage: flow validate <file> | flow run <file> [--execute]".into());
            }
            if command == "validate" && execute {
                return Err("Validation is read-only; omit --execute".into());
            }
            let flow = parse_flow(&fs::read_to_string(path)?)?;
            println!("[ReflexCore] Valid flow: {} steps", flow.steps.len());
            if command == "validate" || !execute {
                println!("[ReflexCore] Preview only. To perform actions: flow run <file> --execute");
                return Ok(());
            }
            execute_flow(&flow, &Cancellation::from_queue())
        }
        _ => Err("Unknown flow command".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> Flow { parse_flow(include_str!("../examples/smoke_flow.json")).unwrap() }

    #[test]
    fn example_is_valid() {
        assert_eq!(fixture().steps.len(), 4);
    }
    #[test]
    fn does_not_allow_shell_actions() {
        let mut f = fixture();
        f.steps[0].action = "powershell".into();
        assert!(validate(&f).is_err());
    }
    #[test]
    fn requires_unique_selector() {
        let mut f = fixture();
        f.steps[0].name = None;
        f.steps[0].id = None;
        f.steps[0].path = None;
        assert!(validate(&f).is_err());
    }
    #[test]
    fn no_unbounded_automatic_retries_of_invoke() {
        assert!(!retry_safe("invoke"));
        assert!(!retry_safe("toggle"));
        assert!(retry_safe("set-value"));
        assert!(retry_safe("assert-value"));
    }
    #[test]
    fn inspect_is_read_only() {
        assert!(!is_mutation("inspect"));
        assert!(!is_mutation("assert-name"));
        assert!(is_mutation("invoke"));
    }
    #[test]
    fn rejects_unknown_json_fields() {
        let bad = r#"{"schema":"reflexcore.flow.v1","name":"x","window":"w","steps":[{"action":"invoke","id":"x","shell":"danger"}]}"#;
        assert!(parse_flow(bad).is_err());
    }
    #[test]
    fn expected_value_is_required_for_assertions() {
        let mut f = fixture();
        f.steps[1].value = None;
        assert!(validate(&f).is_err());
    }
    #[test]
    fn no_sensitive_selectors_in_execution_record() {
        let report = FlowReport {
            schema: "test", started_ms: 1, duration_ms: 2,
            outcome: "passed", completed_steps: 1, total_steps: 1,
            steps: vec![StepReport {
                index: 1, action: "set-value".into(), attempts: 1,
                status: "issued".into(), verification: "verified".into(), duration_ms: 1,
            }],
        };
        let data = serde_json::to_string(&report).unwrap();
        assert!(!data.contains("private@example.com"));
        assert!(!data.contains("name"));
        assert!(data.contains("set-value"));
    }
}