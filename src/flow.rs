//! ReflexCore 0.1.0: deterministic Observe -> Act -> Verify flow runner.
//! The existing UIA action worker is the only actuator; the flow engine never
//! clicks coordinates or executes arbitrary plan-supplied shell commands.
//! This module intentionally saves no UI labels, selectors, text, or values.

use serde::{Deserialize, Serialize};
use crate::task_integrity::{self, Fault};
use std::{
    error::Error,
    fs,
    path::{Path, PathBuf},
    io::Read,
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

type Result<T> = std::result::Result<T, Box<dyn Error>>;
const REPORT: &str = "data/flow_last_run.json";
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
    phases: Vec<serde_json::Value>,
    adapter_us: u128,
    index: usize,
    action: String,
    attempts: usize,
    status: String,
    verification: String,
    duration_ms: u128,
}

#[derive(Debug, Serialize)]
struct FlowReport {
    #[serde(skip_serializing_if = "Option::is_none")]
    execution_run_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    session_close_us: Option<u128>,
    #[serde(skip_serializing_if = "Option::is_none")]
    fixture_ready_us: Option<u128>,
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

#[derive(PartialEq, Eq, Debug)]
enum PendingEffect { None, Unknown, FixtureOutput }

impl PendingEffect {
    fn observe(&mut self, index: usize, action: &str, verification: &str, owned_fixture: bool) {
        if owned_fixture && index == 3 && action == "assert-value" && verification == "verified" && *self == Self::FixtureOutput {
            *self = Self::None;
        } else if is_mutation(action) && verification != "verified" {
            *self = if owned_fixture && index == 2 && action == "invoke" && *self == Self::None {
                Self::FixtureOutput
            } else { Self::Unknown };
        }
    }

    fn preserve_uncertainty(&self, fault: Fault) -> Fault {
        match (self, fault) {
            (Self::None, _) => fault,
            (_, Fault::Cancelled) => Fault::CancelledUnknown,
            (_, Fault::Infrastructure | Fault::FocusLost) => Fault::EffectUnknown,
            (Self::Unknown, Fault::VerificationFailed) => Fault::EffectUnknown,
            _ => fault,
        }
    }
}

fn save_report(report: &FlowReport, owned_fixture: bool) -> Result<()> {
    fs::create_dir_all("data")?;
    fs::write(REPORT, serde_json::to_vec_pretty(report)?)?;
    if owned_fixture {
        if let Ok(run) = std::env::var("REFLEXCORE_BENCHMARK_RUN_ID") {
            save_benchmark_report(Path::new("data/benchmark-runs"), report, &run)?;
        }
    }
    Ok(())
}

fn save_benchmark_report(dir: &Path, report: &FlowReport, run: &str) -> Result<()> {
    if run.len() != 32 || !run.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) {
        return Err("Invalid benchmark run ID".into());
    }
    fs::create_dir_all(dir)?;
    let mut payload = serde_json::to_value(report)?;
    payload["run_id"] = serde_json::json!(run);
    let temp = dir.join(format!("{}.tmp", task_integrity::run_id()));
    let result = fs::write(&temp, serde_json::to_vec(&payload)?)
        .and_then(|_| fs::rename(&temp, dir.join(format!("{run}.json"))));
    if result.is_err() {
        let _ = fs::remove_file(temp);
    }
    result?;
    Ok(())
}

pub(super) fn has_terminal_assertion(bytes: &[u8]) -> bool {
    std::str::from_utf8(bytes).ok()
        .and_then(|source| parse_flow(source).ok())
        .and_then(|flow| flow.steps.last().map(|step| is_assertion(&step.action)))
        .unwrap_or(false)
}

fn execute_flow(flow: &Flow, fixture: Option<(&str, u32)>, fixture_ready_us: Option<u128>) -> Result<()> {
    let _lock = FlowLock::acquire()?;
    execute_scoped_flow(flow, fixture, fixture.is_some(), fixture_ready_us)
}

fn execute_scoped_flow(flow: &Flow, target: Option<(&str, u32)>, trusted_fixture: bool, fixture_ready_us: Option<u128>) -> Result<()> {
    validate(flow)?;
    let started = Instant::now();
    let run_id = task_integrity::run_id();
    let mut final_report = FlowReport {
        execution_run_id: Some(run_id.clone()),
        session_close_us: None,
        fixture_ready_us,
        schema: "reflexcore.flow.execution.v1",
        started_ms: now_ms(),
        duration_ms: 0,
        outcome: "failed",
        completed_steps: 0,
        total_steps: flow.steps.len(),
        steps: Vec::new(),
    };
    let mut action_id = 0;
    let mut session = if trusted_fixture && std::env::var("REFLEXCORE_UIA_WORKER").as_deref() == Ok("session") {
        let (hwnd, pid) = target.ok_or("Session requires an owned fixture")?;
        Some(crate::uia_actions::session::Session::start(&run_id, usize::from_str_radix(hwnd.trim_start_matches("0x"), 16)?, pid)?)
    } else { None };
    let mut pending = PendingEffect::None;
    let mut has_evidence = false;
    for (index, step) in flow.steps.iter().enumerate() {
        let per_step = Instant::now();
        let mut adapter_us = 0;
        let mut phases = Vec::new();
        let mut last_status = "worker_error".to_owned();
        let mut last_verification = "not_applicable".to_owned();
        let attempts_allowed = if retry_safe(&step.action) {
            usize::from(step.retries.unwrap_or(2)) + 1
        } else {
            1 // Never blindly retry an invoke/toggle/select; it may already have happened.
        };
        let mut attempt_count = 0;
        let mut succeeded = false;
        let mut action_fault = None;
        let mut args = build_action_args(flow, step);
        if let Some((hwnd, _)) = target {
            args.remove(1);
            args.insert(1, format!("--hwnd={hwnd}"));
        }
        for attempt in 1..=attempts_allowed {
            attempt_count = attempt;
            action_id += 1;
            let dispatch = Instant::now();
            let response = crate::uia_actions::dispatch(&args[1..], &run_id, action_id,
                target.map(|(_, pid)| pid), target.is_some() && !trusted_fixture, session.as_mut());
            adapter_us += dispatch.elapsed().as_micros();
            match response {
                Ok(response) => {
                    if let Some(sample) = response.get("phases") { phases.push(sample.clone()); }
                    last_status = response["status"].as_str().unwrap_or("invalid_report").to_owned();
                    last_verification = response["verification"].as_str().unwrap_or("not_applicable").to_owned();
                    if last_status == "action_error" { action_fault = Some(Fault::EffectUnknown); }
                    if last_status == "focus_lost" { action_fault = Some(Fault::FocusLost); }
                    if last_status == "cancelled" { action_fault = Some(Fault::Cancelled); }
                    succeeded = match step.action.as_str() {
                        "inspect" => last_status == "inspected",
                        "assert-name" | "assert-value" =>
                            last_status == "assertion_passed" && last_verification == "verified",
                        _ => last_status == "issued",
                    };
                }
                Err(error) => {
                    last_status = "worker_error".to_owned();
                    last_verification = "unknown".to_owned();
                    action_fault = Some(error.downcast_ref::<Fault>().copied().unwrap_or(if is_mutation(&step.action) {
                        Fault::EffectUnknown
                    } else { Fault::Infrastructure }));
                }
            }
            if succeeded || action_fault.is_some() { break; }
            if attempt < attempts_allowed && last_status != "ambiguous" {
                thread::sleep(Duration::from_millis(250));
            } else { break; }
        }
        if succeeded {
            // The owned demo's Apply handler copies Input to the independent Output field.
            let trusted_fixture_step = trusted_fixture && match index {
                2 => step.name.as_deref() == Some("Apply"),
                3 => step.name.as_deref() == Some("ReflexCore Output") && step.value == flow.steps[0].value,
                _ => false,
            };
            pending.observe(index, &step.action, &last_verification, trusted_fixture_step);
            has_evidence |= last_verification == "verified";
        }
        final_report.steps.push(StepReport {
            phases,
            adapter_us,
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
            final_report.session_close_us = session.take().map(|worker| worker.close());
            final_report.duration_ms = started.elapsed().as_millis();
            let fault = action_fault.unwrap_or(match (last_status.as_str(), &pending) {
                ("assertion_failed", PendingEffect::FixtureOutput) if index == 3 => Fault::VerificationFailed,
                ("assertion_failed", PendingEffect::None) => Fault::PreconditionFailed,
                _ => Fault::Infrastructure,
            });
            let fault = pending.preserve_uncertainty(fault);
            final_report.outcome = match fault {
                Fault::Cancelled | Fault::CancelledUnknown => "cancelled",
                Fault::EffectUnknown => "completed_unverified",
                _ => "failed",
            };
            save_report(&final_report, trusted_fixture)?;
            return Err(fault.into());
        }
        final_report.completed_steps += 1;
    }
    final_report.session_close_us = session.take().map(|worker| worker.close());
    final_report.duration_ms = started.elapsed().as_millis();
    if task_integrity::cancelled() {
        final_report.outcome = "cancelled";
        save_report(&final_report, trusted_fixture)?;
        return Err(pending.preserve_uncertainty(Fault::Cancelled).into());
    }
    if pending != PendingEffect::None || !has_evidence {
        final_report.outcome = "completed_unverified";
        save_report(&final_report, trusted_fixture)?;
        return Err(Fault::EffectUnknown.into());
    }
    final_report.outcome = "passed";
    save_report(&final_report, trusted_fixture)?;
    println!("[ReflexCore] FLOW PASSED: {} steps, {} ms", flow.steps.len(), final_report.duration_ms);
    println!("[Privacy] Redacted execution report: {REPORT}");
    Ok(())
}

fn fixture_window(pid: Option<u32>) -> Option<String> {
    crate::observer::find_window_handle("ReflexCore Test Window", pid)
}

struct FixtureProcess(Child);
impl Drop for FixtureProcess {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn demo(execute: bool, count: usize) -> Result<()> {
    let mut flow = parse_flow(include_str!("../examples/smoke_flow.json"))?;
    match count {
        1 => {
            let mut check = flow.steps[1].clone();
            check.value = Some(String::new());
            flow.steps = vec![check];
        }
        4 | 20 | 100 => flow.steps.resize(count, flow.steps[3].clone()),
        _ => return Err("Fixture length must be 1, 4, 20 or 100".into()),
    }
    if !execute {
        println!("[ReflexCore] Demo has {} steps; no changes made.", flow.steps.len());
        println!("[ReflexCore] To run against a temporary test window: flow demo --execute");
        return Ok(());
    }
    let started = Instant::now();
    let (fixture, hwnd) = start_fixture(None, false)?;
    execute_flow(&flow, Some((&hwnd, fixture.0.id())), Some(started.elapsed().as_micros()))
}

fn start_fixture(save_to: Option<&Path>, background: bool) -> Result<(FixtureProcess, String)> {
    task_integrity::check_cancel()?;
    if fixture_window(None).is_some() {
        return Err("A ReflexCore Test Window already exists; close it before demo".into());
    }
    let path = Path::new("tools/ReflexCore-Fixture.ps1");
    if !path.is_file() {
        return Err("Missing test fixture: tools/ReflexCore-Fixture.ps1".into());
    }
    let mut command = Command::new("powershell.exe");
    command.args(["-NoProfile", "-Sta", "-NonInteractive", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File"])
        .arg(path)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .env_remove("REFLEXCORE_FIXTURE_SAVE_PATH")
        .env_remove("REFLEXCORE_FIXTURE_BACKGROUND");
    if background {
        use std::os::windows::process::CommandExt;
        use windows::Win32::System::Threading::CREATE_NO_WINDOW;
        command.creation_flags(CREATE_NO_WINDOW.0);
        command.env("REFLEXCORE_FIXTURE_BACKGROUND", "1");
    }
    if let Some(path) = save_to {
        command.env("REFLEXCORE_FIXTURE_SAVE_PATH", path);
    }
    let child = command.spawn()?;
    let mut fixture = FixtureProcess(child);
    let started = Instant::now();
    let hwnd = loop {
        task_integrity::check_cancel()?;
        if let Some(hwnd) = fixture_window(Some(fixture.0.id())) { break hwnd; }
        if fixture.0.try_wait()?.is_some() {
            return Err("Windows Forms test fixture exited before opening".into());
        }
        if started.elapsed() > Duration::from_secs(10) {
            return Err("Test fixture did not open within 10 seconds".into());
        }
        thread::sleep(Duration::from_millis(150));
    };
    Ok((fixture, hwnd))
}

struct FixtureArtifact(PathBuf, bool);

impl FixtureArtifact {
    fn new(run: &str) -> Result<Self> {
        let dir = crate::skill_registry::saved_text::winforms_folder(run)?;
        fs::create_dir(&dir)?;
        Ok(Self(dir, false))
    }

    fn path(&self) -> PathBuf {
        self.0.join("saved.txt")
    }
}

impl Drop for FixtureArtifact {
    fn drop(&mut self) {
        if self.1 { return; } // A composed Goal retains its original synthetic document.
        let _ = fs::remove_file(self.path());
        let _ = fs::remove_dir(&self.0);
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum FixtureState {
    Empty,
    Prepared,
    Saved,
}

impl FixtureState {
    fn id(self) -> &'static str {
        match self {
            Self::Empty => "empty",
            Self::Prepared => "prepared",
            Self::Saved => "saved",
        }
    }
}

fn verify_transition<T>(
    ctx: &mut T,
    from: FixtureState,
    to: FixtureState,
    mut observe: impl FnMut(&mut T, FixtureState) -> Result<bool>,
    dispatch: impl FnOnce(&mut T) -> Result<()>,
) -> Result<()> {
    task_integrity::check_cancel()?;
    match observe(ctx, from) {
        Ok(true) => {}
        Ok(false) => return Err(Fault::PreconditionFailed.into()),
        Err(error) => return Err(error),
    }
    task_integrity::check_cancel()?;
    dispatch(ctx)?;
    task_integrity::check_cancel().map_err(|_| Fault::CancelledUnknown)?;
    match observe(ctx, to) {
        Ok(true) => Ok(()),
        Ok(false) => Err(Fault::VerificationFailed.into()),
        Err(error) if matches!(error.downcast_ref::<Fault>(), Some(Fault::Cancelled | Fault::CancelledUnknown)) =>
            Err(Fault::CancelledUnknown.into()),
        Err(_) => Err(Fault::EffectUnknown.into()),
    }
}

pub(crate) fn verified_demo<'a>(background: bool, run: &'a str, composition: Option<&crate::skill_registry::composition::Plan>) -> Result<crate::skill_registry::saved_text::Evidence<'a>> {
    use crate::skill_registry::saved_text::{self, Adapter};
    let start = Instant::now();
    let binding = saved_text::bind(saved_text::ID, 1, Adapter::Winforms, background)?;
    let bind_ns = start.elapsed().as_nanos();
    let measure = std::env::var("REFLEXCORE_SKILL_TIMINGS").as_deref() == Ok("1");
    task_integrity::check_cancel()?;
    let skills = [
        ("prepare-editor", FixtureState::Empty, FixtureState::Prepared, 0),
        ("save-document", FixtureState::Prepared, FixtureState::Saved, 2),
    ];
    let edges = skills.map(|(id, from, to, _)| (id, from.id(), to.id(), 1));
    let planning = Instant::now();
    let plan = crate::agent::plan_edges(FixtureState::Empty.id(), FixtureState::Saved.id(), &edges)?;
    let plan_us = planning.elapsed().as_micros();
    let _lock = FlowLock::acquire()?;
    let mut artifact = FixtureArtifact::new(run)?;
    artifact.1 = composition.is_some();
    let path = artifact.path();
    let (fixture, hwnd) = start_fixture(Some(&path), background)?;
    let owned = (&*hwnd, fixture.0.id());
    let flow = parse_flow(include_str!("../examples/smoke_flow.json"))?;
    let expected = flow.steps[0].value.as_deref().ok_or("Missing fixture text")?;
    let mut session = if std::env::var("REFLEXCORE_UIA_WORKER").as_deref() == Ok("session") {
        Some(crate::uia_actions::session::Session::start(run, usize::from_str_radix(hwnd.trim_start_matches("0x"), 16)?, owned.1)?)
    } else { None };
    let mut next = 0;
    let mut timings = Vec::new();
    let mut action = |step: &Step| -> Result<serde_json::Value> {
        if background && !matches!(step.action.as_str(), "set-value" | "invoke" | "assert-value") {
            return Err(Fault::PreconditionFailed.into());
        }
        if fixture_window(Some(owned.1)).as_deref() != Some(owned.0) {
            return Err(Fault::FocusLost.into());
        }
        let mut args = build_action_args(&flow, step);
        args[1] = format!("--hwnd={hwnd}");
        next += 1;
        let started = Instant::now();
        let reply = crate::uia_actions::dispatch(&args[1..], run, next, Some(owned.1), false, session.as_mut())?;
        if measure {
            let phases = &reply["phases"];
            timings.push(serde_json::json!({
                "action": next, "elapsed_us": started.elapsed().as_micros(),
                "spawn_us": phases["spawn_us"], "com_us": phases["com_us"], "uia_us": phases["uia_us"],
                "concurrent_private_bytes": phases["concurrent_private_bytes"], "child_cpu_us": phases["child_cpu_us"],
                "root_cpu_us": phases["root_cpu_us"]
            }));
        }
        Ok(reply)
    };
    let read_saved = || -> Result<bool> {
        match binding.verify_winforms(run, expected) {
            Ok(_) => Ok(true),
            Err(Fault::VerificationFailed) => Ok(false),
            Err(fault) => Err(fault.into()),
        }
    };
    // Both skills use the same owned window. The final effect is checked on disk.
    for index in plan {
        let (_, from, to, step) = skills[index];
        verify_transition(&mut action, from, to, |action, state| {
            if state == FixtureState::Saved {
                return read_saved();
            }
            let mut assertion = flow.steps[1].clone();
            assertion.value = Some(if state == FixtureState::Empty { "" } else { expected }.into());
            fixture_value_matches(action(&assertion)?)
        }, |action| {
            if to == FixtureState::Saved && path.try_exists()? {
                return Err(Fault::PreconditionFailed.into());
            }
            let reply = action(&flow.steps[step]).map_err(|error| {
                error.downcast_ref::<Fault>().copied().unwrap_or(Fault::EffectUnknown)
            })?;
            match reply["status"].as_str() {
                Some("issued") => Ok(()),
                Some("cancelled") => Err(Fault::Cancelled.into()),
                Some("focus_lost") => Err(Fault::FocusLost.into()),
                _ => Err(Fault::EffectUnknown.into()),
            }
        })?;
    }
    let evidence = if let Some(plan)=composition {plan.finish(run, expected)?} else if saved_text::transfer_check_enabled() {
        binding.verify_transfer(run, expected)?
    } else { binding.verify_winforms(run, expected)? };
    if measure {
        println!("{}", serde_json::json!({"schema":"reflexcore.skill.timing.v1", "run_id":run,
            "bind_ns":bind_ns, "plan_us":plan_us, "actions":timings}));
    }
    println!("[ReflexCore] GOAL VERIFIED: two guarded skills and independent file readback");
    Ok(evidence)
}

fn fixture_value_matches(reply: serde_json::Value) -> Result<bool> {
    match reply["status"].as_str() {
        Some("assertion_passed") if reply["verification"] == "verified" => Ok(true),
        Some("assertion_failed") => Ok(false),
        Some("cancelled") => Err(Fault::Cancelled.into()),
        _ => Err(Fault::EffectUnknown.into()),
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ValuePredicate {
    pub(crate) automation_id: String,
    pub(crate) equals: String,
}

pub(crate) struct GoalWindow {
    title: String,
    hwnd: String,
    pid: u32,
    _lock: FlowLock,
}

impl GoalWindow {
    pub(crate) fn bind(title: &str) -> Result<Self> {
        let lock = FlowLock::acquire()?;
        let (hwnd, pid) = Self::resolve(title)?;
        Ok(Self { title: title.into(), hwnd, pid, _lock: lock })
    }

    fn resolve(title: &str) -> Result<(String, u32)> {
        let windows = crate::observer::capture_value()?;
        let mut matches = windows["windows"].as_array().ok_or(Fault::Infrastructure)?
            .iter().filter(|w| w["title"].as_str() == Some(title));
        let window = matches.next().ok_or(Fault::PreconditionFailed)?;
        if matches.next().is_some() || window["active"] != true {
            return Err(Fault::PreconditionFailed.into());
        }
        Ok((
            window["hwnd"].as_str().ok_or(Fault::Infrastructure)?.into(),
            u32::try_from(window["pid"].as_u64().ok_or(Fault::Infrastructure)?)?,
        ))
    }

    pub(crate) fn observe(&self, predicate: &ValuePredicate) -> Result<bool> {
        let (hwnd, pid) = Self::resolve(&self.title)?;
        if hwnd != self.hwnd || pid != self.pid {
            return Err(Fault::FocusLost.into());
        }
        let args = [
            format!("--hwnd={}", self.hwnd), "--action=assert-value".into(),
            format!("--id={}", predicate.automation_id), format!("--value={}", predicate.equals),
            "--timeout-ms=2000".into(),
        ];
        let reply = crate::uia_actions::execute_scoped(&args, &task_integrity::run_id(), 1, Some(self.pid), true)?;
        fixture_value_matches(reply)
    }

    pub(crate) fn run_flow(&self, path: &str) -> Result<()> {
        let mut text = String::new();
        fs::File::open(path)?.take(2 * 1024 * 1024 + 1).read_to_string(&mut text)?;
        if text.len() > 2 * 1024 * 1024 { return Err("Flow exceeds 2 MiB".into()); }
        let flow = parse_flow(&text)?;
        if flow.window != self.title || flow.steps.iter().any(|step| step.window.is_some() || step.path.is_some()) {
            return Err("Guarded flows require one window and named selectors".into());
        }
        execute_scoped_flow(&flow, Some((&self.hwnd, self.pid)), false, None)
    }
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
            demo(execute, 4)
        }
        "measure-fixture" if args.len() == 3 && args[1] == "--execute" => demo(true, args[2].parse()?),
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
            execute_flow(&flow, None, None)
        }
        _ => Err("Unknown flow command".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn changed_state_blocks_the_next_skill() {
        let mut dispatches = 0;
        let error = verify_transition(&mut dispatches, FixtureState::Prepared, FixtureState::Saved,
            |_, _| Ok(false), |count| { *count += 1; Ok(()) }).unwrap_err();
        assert!(matches!(error.downcast_ref::<Fault>(), Some(Fault::PreconditionFailed)));
        assert_eq!(dispatches, 0);
    }

    #[test]
    fn lost_effect_evidence_does_not_repeat_dispatch() {
        let mut dispatches = 0;
        let error = verify_transition(&mut dispatches, FixtureState::Prepared, FixtureState::Saved,
            |_, state| {
                if state == FixtureState::Prepared { Ok(true) } else { Err("Unavailable readback".into()) }
            },
            |count| { *count += 1; Ok(()) }).unwrap_err();
        assert!(matches!(error.downcast_ref::<Fault>(), Some(Fault::EffectUnknown)));
        assert_eq!(dispatches, 1);
    }

    #[test]
    fn overlapping_benchmark_reports_keep_their_run_identity() {
        let artifact = FixtureArtifact::new(&task_integrity::run_id()).unwrap();
        let report = FlowReport {
            execution_run_id: None,
            session_close_us: None,
            fixture_ready_us: None,
            schema: "reflexcore.flow.execution.v1", started_ms: 0, duration_ms: 1,
            outcome: "passed", completed_steps: 0, total_steps: 0, steps: vec![],
        };
        let runs = ["0123456789abcdef0123456789abcdef", "abcdef0123456789abcdef0123456789"];
        std::thread::scope(|scope| {
            for run in runs {
                let dir = &artifact.0;
                let report = &report;
                scope.spawn(move || save_benchmark_report(dir, report, run).unwrap());
            }
        });
        for run in runs {
            let path = artifact.0.join(format!("{run}.json"));
            let bytes = fs::read(&path).unwrap();
            fs::remove_file(path).unwrap();
            let value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
            assert_eq!(value["run_id"], run);
        }
    }

    #[test]
    fn unrelated_assertions_cannot_confirm_an_effect() {
        let mut pending = PendingEffect::None;
        pending.observe(2, "invoke", "not_verified", false);
        pending.observe(3, "assert-name", "verified", false);
        pending.observe(4, "set-value", "verified", false);
        assert_eq!(pending, PendingEffect::Unknown);
        assert!(matches!(pending.preserve_uncertainty(Fault::Infrastructure), Fault::EffectUnknown));
        assert!(matches!(pending.preserve_uncertainty(Fault::Cancelled), Fault::CancelledUnknown));
        let mut fixture = PendingEffect::None;
        fixture.observe(2, "invoke", "not_verified", true);
        fixture.observe(3, "assert-value", "failed", true);
        assert_eq!(fixture, PendingEffect::FixtureOutput);
        fixture.observe(3, "assert-value", "verified", true);
        assert_eq!(fixture, PendingEffect::None);
        let mut confirmed = PendingEffect::None;
        confirmed.observe(0, "set-value", "verified", false);
        assert_eq!(confirmed, PendingEffect::None);
    }

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
            execution_run_id: None,
            session_close_us: None,
            fixture_ready_us: None,
            schema: "test", started_ms: 1, duration_ms: 2,
            outcome: "passed", completed_steps: 1, total_steps: 1,
            steps: vec![StepReport {
                index: 1, action: "set-value".into(), attempts: 1,
                status: "issued".into(), verification: "verified".into(), duration_ms: 1, adapter_us: 1000, phases: Vec::new(),
            }],
        };
        let data = serde_json::to_string(&report).unwrap();
        assert!(!data.contains("private@example.com"));
        assert!(!data.contains("name"));
        assert!(data.contains("set-value"));
    }
}
