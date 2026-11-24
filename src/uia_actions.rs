//! ReflexCore 0.0.5: guarded native UIA action engine.
//! The parent supervises a disposable COM worker; mutations require --execute.
//! No broad credential capture, no raw keyboard injection, no arbitrary shell execution.

use serde_json::{json, Value};
use std::{
    error::Error,
    ffi::c_void,
    fs,
    io::Read,
    path::PathBuf,
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use windows::{
    core::BSTR,
    Win32::{
        Foundation::HWND,
        System::Com::{
            CoCreateInstance, CoInitializeEx, CoUninitialize,
            CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED,
        },
        UI::Accessibility::{
            CUIAutomation, IUIAutomation, IUIAutomationElement,
            IUIAutomationTreeWalker, IUIAutomationInvokePattern,
            IUIAutomationValuePattern, IUIAutomationTogglePattern,
            IUIAutomationSelectionItemPattern, UIA_InvokePatternId,
            UIA_ValuePatternId, UIA_TogglePatternId, UIA_SelectionItemPatternId,
        },
    },
};

type Result<T> = std::result::Result<T, Box<dyn Error>>;

#[derive(Clone, Debug)]
struct Request {
    window: Option<String>,
    hwnd: Option<usize>,
    name: Option<String>,
    automation_id: Option<String>,
    path: Option<String>,
    kind: Option<String>,
    action: String,
    value: Option<String>,
    execute: bool,
    timeout_ms: u64,
    max_nodes: usize,
}

impl Default for Request {
    fn default() -> Self {
        Self {
            window: None, hwnd: None,
            name: None, automation_id: None, path: None, kind: None,
            action: "inspect".into(), value: None, execute: false,
            timeout_ms: 30_000, max_nodes: 0, // no fixed node cap
        }
    }
}

fn parse_hwnd(text: &str) -> Result<usize> {
    let hex = text.trim().strip_prefix("0x")
        .or_else(|| text.trim().strip_prefix("0X"))
        .unwrap_or(text.trim());
    Ok(usize::from_str_radix(hex, 16)?)
}

fn parse(args: &[String]) -> Result<Request> {
    let mut req = Request::default();
    for arg in args {
        if arg == "--execute" {
            req.execute = true;
        } else if arg == "--active" {
            if req.window.is_some() || req.hwnd.is_some() {
                return Err("--active conflicts with window selection".into());
            }
        } else if let Some(v) = arg.strip_prefix("--hwnd=") {
            if req.window.is_some() || req.hwnd.is_some() {
                return Err("Specify only one window selector".into());
            }
            req.hwnd = Some(parse_hwnd(v)?);
        } else if let Some(v) = arg.strip_prefix("--name=") {
            req.name = Some(v.into());
        } else if let Some(v) = arg.strip_prefix("--id=") {
            req.automation_id = Some(v.into());
        } else if let Some(v) = arg.strip_prefix("--path=") {
            req.path = Some(v.into());
        } else if let Some(v) = arg.strip_prefix("--type=") {
            req.kind = Some(v.into());
        } else if let Some(v) = arg.strip_prefix("--action=") {
            req.action = v.into();
        } else if let Some(v) = arg.strip_prefix("--value=") {
            req.value = Some(v.into());
        } else if let Some(v) = arg.strip_prefix("--timeout-ms=") {
            req.timeout_ms = v.parse()?;
        } else if let Some(v) = arg.strip_prefix("--max-nodes=") {
            req.max_nodes = v.parse()?;
        } else if arg.starts_with('-') {
            return Err(format!("Unknown option: {arg}").into());
        } else if req.window.is_none() && req.hwnd.is_none() {
            req.window = Some(arg.clone());
        } else {
            return Err("Unexpected positional argument".into());
        }
    }
    if !matches!(req.action.as_str(), "inspect" | "focus" | "invoke" | "toggle" | "select" | "set-value" | "assert-value" | "assert-name") {
        return Err("--action must be inspect, focus, invoke, toggle, select, set-value, assert-value, or assert-name".into());
    }
    if req.name.is_none() && req.automation_id.is_none() && req.path.is_none() {
        return Err("Provide --name=, --id=, or --path= to identify an element".into());
    }
    if req.timeout_ms < 100 || req.timeout_ms > 300_000 {
        return Err("--timeout-ms must be between 100 and 300000".into());
    }
    if matches!(req.action.as_str(), "set-value" | "assert-value" | "assert-name") && req.value.is_none() {
        return Err("set-value/assert-value/assert-name require --value=...".into());
    }
    if !matches!(req.action.as_str(), "set-value" | "assert-value" | "assert-name") && req.value.is_some() {
        return Err("--value is valid only for set-value/assert-value/assert-name".into());
    }
    if matches!(req.action.as_str(), "inspect" | "assert-value" | "assert-name") && req.execute {
        return Err("inspect is read-only: omit --execute".into());
    }
    if req.path.as_ref().is_some_and(|p| !valid_path(p)) {
        return Err("--path must be a UIA tree path like 0/1/2".into());
    }
    Ok(req)
}

fn valid_path(path: &str) -> bool {
    if path.len() > 192 { return false; }
    let mut segments = path.split('/');
    if segments.next() != Some("0") { return false; }
    let mut depth=0usize;
    for segment in segments {
        depth+=1;
        if depth>32 || segment.is_empty() || (segment.len()>1 && segment.starts_with('0')) ||
           !segment.parse::<usize>().is_ok_and(|index|index<=1024) {return false;}
    }
    true
}

fn resolve_window(req: &Request) -> Result<(usize, String)> {
    let observation = crate::observer::capture_value()?;
    let windows = observation["windows"].as_array()
        .ok_or("Observer returned invalid windows")?;

    if let Some(handle) = req.hwnd {
        let found = windows.iter().find(|w| {
            w["hwnd"].as_str().and_then(|s| parse_hwnd(s).ok()) == Some(handle)
        }).ok_or("HWND was not found among visible windows")?;
        return Ok((handle, found["title"].as_str().unwrap_or("").into()));
    }

    let mut candidates: Vec<&Value> = windows.iter().filter(|w| match &req.window {
        Some(title) => w["title"].as_str().is_some_and(|s| {
            s.to_lowercase().contains(&title.to_lowercase())
        }),
        None => w["active"].as_bool() == Some(true),
    }).collect();
    candidates.sort_by_key(|w| {
        let exact = req.window.as_ref().is_some_and(|title| {
            w["title"].as_str().is_some_and(|s| s.to_lowercase() == title.to_lowercase())
        });
        (!exact, w["active"].as_bool() != Some(true))
    });
    let first = candidates.first().ok_or("Window not found. Use 'cargo run -- windows'.")?;
    let hwnd = parse_hwnd(first["hwnd"].as_str().ok_or("Missing HWND")?)?;
    Ok((hwnd, first["title"].as_str().unwrap_or("").into()))
}

fn now_ms() -> Result<u128> {
    Ok(SystemTime::now().duration_since(UNIX_EPOCH)?.as_millis())
}

pub fn run(args: &[String]) -> Result<()> {
    let req = parse(args)?;
    let run_id = crate::task_integrity::run_id();
    let report = execute(args, &run_id, 1, None)?;
    fs::create_dir_all("data")?;
    fs::write("data/uia_last_action.json", serde_json::to_vec_pretty(&report)?)?;
    print_report(&req, &report);
    Ok(())
}

pub(crate) fn execute(args: &[String], run_id: &str, action_id: usize, fixture_owner: Option<u32>) -> Result<Value> {
    execute_scoped(args, run_id, action_id, fixture_owner, false)
}

pub(crate) fn execute_scoped(args: &[String], run_id: &str, action_id: usize, owner: Option<u32>, foreground: bool) -> Result<Value> {
    crate::task_integrity::check_cancel()?;
    let req = parse(args)?;
    let (hwnd, window_title) = resolve_window(&req).map_err(|_| crate::task_integrity::Fault::Infrastructure)?;
    let request = crate::task_integrity::ActionExchange::new(run_id, action_id)?;
    let temp = request.path();
    crate::task_integrity::check_cancel()?;
    let mut wire = req.to_wire();
    wire["fixture_owner"] = json!(owner);
    wire["require_foreground"] = json!(foreground);
    use std::os::windows::process::CommandExt;
    use windows::Win32::System::Threading::CREATE_NO_WINDOW;
    let mut child = Command::new(std::env::current_exe()?)
        .creation_flags(CREATE_NO_WINDOW.0)
        .arg("uia-act-worker")
        .arg(hwnd.to_string())
        .arg(&temp)
        .arg(request.encode(wire)?)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()?;

    let started = Instant::now();
    let limit = Duration::from_millis(req.timeout_ms.saturating_add(1_500));
    let status = loop {
        if let Some(s) = child.try_wait()? { break s; }
        let stopped = crate::task_integrity::cancelled();
        if stopped || started.elapsed() >= limit {
            let _ = child.kill();
            let _ = child.wait();
            let _ = fs::remove_file(&temp);
            if stopped { return Err(crate::task_integrity::Fault::CancelledUnknown.into()); }
            return Err("UIA action worker timed out; result may be unknown if an action was already issued".into());
        }
        thread::sleep(Duration::from_millis(25));
    };
    if !status.success() && crate::task_integrity::cancelled() {
        return Err(crate::task_integrity::Fault::CancelledUnknown.into());
    }
    if !status.success() {
        let _ = fs::remove_file(&temp);
        let mut err = String::new();
        if let Some(mut stream) = child.stderr.take() {
            let _ = stream.read_to_string(&mut err);
        }
        return Err(format!("UIA action worker failed: {status}. {}", err.trim()).into());
    }

    let mut report = request.read()?;
    report["window_title"] = json!(window_title);
    report["window_hwnd"] = json!(format!("0x{hwnd:X}"));
    crate::privacy::sanitize_uia_report(&mut report);

    Ok(report)
}

fn print_report(req: &Request, report: &Value) {
    println!("ReflexCore UIA Action Engine 0.0.5");
    println!("Window: {} [{}]", report["window_title"].as_str().unwrap_or(""), report["window_hwnd"].as_str().unwrap_or(""));
    println!("Action: {} | execute: {} | nodes scanned: {} | matches: {}",
        req.action, req.execute, report["nodes_scanned"], report["match_count"]);
    if let Some(arr) = report["matches"].as_array() {
        for m in arr.iter().take(10) {
            println!("  {} | {:?} | id={:?} | type={:?}",
                m["path"].as_str().unwrap_or("?"),
                m["name"].as_str().unwrap_or(""),
                m["automation_id"].as_str().unwrap_or(""),
                m["type"].as_str().unwrap_or(""));
        }
    }
    println!("Result: {} | verification: {}", report["status"], report["verification"]);
    if let Some(error) = report.get("error").and_then(Value::as_str) {
        eprintln!("UIA error: {error}");
    }
    println!("Report: data/uia_last_action.json");
}

impl Request {
    // Encode the request for the isolated worker. Avoid serializing full UIA trees.
    fn to_wire(&self) -> Value {
        json!({
            "name": self.name,
            "automation_id": self.automation_id,
            "path": self.path,
            "kind": self.kind,
            "action": self.action,
            "value": self.value,
            "execute": self.execute,
            "timeout_ms": self.timeout_ms,
            "max_nodes": self.max_nodes,
        })
    }
}

struct ComApartment;
impl ComApartment {
    fn enter() -> windows::core::Result<Self> {
        unsafe { CoInitializeEx(None, COINIT_MULTITHREADED).ok()?; }
        Ok(Self)
    }
}
impl Drop for ComApartment {
    fn drop(&mut self) { unsafe { CoUninitialize(); } }
}

struct Frame {
    element: IUIAutomationElement,
    path: String,
}

fn matches(element: &IUIAutomationElement, path: &str, req: &Value) -> bool {
    let by_path = req["path"].as_str()
        .is_none_or(|wanted| wanted == path);
    if !by_path { return false; }
    let by_id = req["automation_id"].as_str().is_none_or(|wanted| {
        unsafe { element.CurrentAutomationId() }
            .is_ok_and(|actual| actual.to_string() == wanted)
    });
    if !by_id { return false; }
    let by_name = req["name"].as_str().is_none_or(|wanted| {
        unsafe { element.CurrentName() }
            .is_ok_and(|actual| actual.to_string().to_lowercase() == wanted.to_lowercase())
    });
    if !by_name { return false; }
    req["kind"].as_str().is_none_or(|wanted| {
        unsafe { element.CurrentLocalizedControlType() }
            .is_ok_and(|actual| actual.to_string().to_lowercase() == wanted.to_lowercase())
    })
}

fn label(element: &IUIAutomationElement, path: &str) -> Value {
    let password = unsafe { element.CurrentIsPassword() }
        .ok().is_some_and(|v| v.as_bool());
    json!({
        "path": path,
        "name": if password { String::from("[password element]") } else {
            unsafe { element.CurrentName() }.map(|v| v.to_string().chars().take(256).collect::<String>()).unwrap_or_default()
        },
        "automation_id": unsafe { element.CurrentAutomationId() }.map(|v| v.to_string()).unwrap_or_default(),
        "type": unsafe { element.CurrentLocalizedControlType() }.map(|v| v.to_string()).unwrap_or_default(),
        "enabled": unsafe { element.CurrentIsEnabled() }.ok().map(|v| v.as_bool()),
        "password": password,
    })
}

fn capabilities(element: &IUIAutomationElement) -> Value {
    json!({
        "focusable": unsafe { element.CurrentIsKeyboardFocusable() }.ok().map(|v| v.as_bool()),
        "invoke": unsafe { element.GetCurrentPatternAs::<IUIAutomationInvokePattern>(UIA_InvokePatternId) }.is_ok(),
        "value": unsafe { element.GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId) }.is_ok(),
        "toggle": unsafe { element.GetCurrentPatternAs::<IUIAutomationTogglePattern>(UIA_TogglePatternId) }.is_ok(),
        "select": unsafe { element.GetCurrentPatternAs::<IUIAutomationSelectionItemPattern>(UIA_SelectionItemPatternId) }.is_ok(),
    })
}

fn verify_assertion(element: &IUIAutomationElement, request: &Value) -> Result<bool> {
    let expected = request["value"].as_str().ok_or("Missing expected value")?;
    match request["action"].as_str() {
        Some("assert-name") => {
            Ok(unsafe { element.CurrentName()? }.to_string() == expected)
        }
        Some("assert-value") => {
            // Never log or persist the value read from this UI element.
            // Refuse password elements even for read-only comparisons.
            let is_password = unsafe { element.CurrentIsPassword()? }.as_bool();
            if is_password {
                return Err("Cannot assert password field values".into());
            }
            let p: IUIAutomationValuePattern = unsafe {
                element.GetCurrentPatternAs(UIA_ValuePatternId)?
            };
            Ok(unsafe { p.CurrentValue()? }.to_string() == expected)
        }
        _ => Err("Unsupported read-only assertion".into()),
    }
}

fn apply(element: &IUIAutomationElement, request: &Value) -> Result<&'static str> {
    let action = request["action"].as_str().ok_or("Missing action")?;
    let is_password = unsafe { element.CurrentIsPassword() }
        .ok().is_some_and(|v| v.as_bool());
    let enabled = unsafe { element.CurrentIsEnabled() }
        .ok().is_some_and(|v| v.as_bool());
    if !enabled { return Err("Target element is disabled or its state is unavailable".into()); }
    if action == "set-value" && is_password {
        return Err("Refusing to set a password element via CLI".into());
    }

    match action {
        "focus" => {
            unsafe { element.SetFocus()?; }
            Ok(if unsafe { element.CurrentHasKeyboardFocus() }.ok().is_some_and(|v| v.as_bool()) {
                "verified" } else { "not_verified" })
        }
        "invoke" => {
            let p: IUIAutomationInvokePattern = unsafe { element.GetCurrentPatternAs(UIA_InvokePatternId)? };
            unsafe { p.Invoke()?; }
            Ok("not_verified")
        }
        "toggle" => {
            let p: IUIAutomationTogglePattern = unsafe { element.GetCurrentPatternAs(UIA_TogglePatternId)? };
            let before = unsafe { p.CurrentToggleState() }.ok();
            unsafe { p.Toggle()?; }
            let after = unsafe { p.CurrentToggleState() }.ok();
            Ok(if before.is_some() && after.is_some() && before != after { "verified" } else { "not_verified" })
        }
        "select" => {
            let p: IUIAutomationSelectionItemPattern = unsafe { element.GetCurrentPatternAs(UIA_SelectionItemPatternId)? };
            unsafe { p.Select()?; }
            Ok(if unsafe { p.CurrentIsSelected() }.ok().is_some_and(|v| v.as_bool()) {
                "verified" } else { "not_verified" })
        }
        "set-value" => {
            let value = request["value"].as_str().ok_or("Missing value")?;
            let p: IUIAutomationValuePattern = unsafe { element.GetCurrentPatternAs(UIA_ValuePatternId)? };
            if unsafe { p.CurrentIsReadOnly()? }.as_bool() {
                return Err("Target value is read-only".into());
            }
            unsafe { p.SetValue(&BSTR::from(value))?; }
            Ok(if unsafe { p.CurrentValue() }.ok().is_some_and(|v| v.to_string() == value) {
                "verified" } else { "not_verified" })
        }
        _ => Err("Unsupported action".into()),
    }
}

pub fn run_worker(args: &[String]) -> Result<()> {
    if args.len() != 3 { return Err("Invalid action worker arguments".into()); }
    let hwnd: usize = args[0].parse()?;
    let output = PathBuf::from(&args[1]);
    let mut request = crate::task_integrity::ActionEnvelope::decode(args[2].as_bytes())?;
    let req = &request.payload;
    let fixture_owner = req["fixture_owner"].as_u64().map(u32::try_from).transpose()?;
    let target_window = hwnd as *mut c_void;
    if fixture_owner.is_some_and(|owner| owner != crate::observer::window_process(target_window)) {
        return Err("Owned UIA fixture disappeared".into());
    }
    let timeout_ms = req["timeout_ms"].as_u64().ok_or("Missing timeout")?;
    let max_nodes = req["max_nodes"].as_u64().ok_or("Missing max_nodes")? as usize;
    let started = Instant::now();
    let _com = ComApartment::enter()?;
    let automation: IUIAutomation = unsafe {
        CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER)?
    };
    let root = unsafe { automation.ElementFromHandle(HWND(hwnd as *mut c_void))? };
    let walker: IUIAutomationTreeWalker = unsafe { automation.RawViewWalker()? };

    // Addressed path only: walk that path directly, no full-tree scan.
    let direct = req["path"].as_str().map(|path| {
        let mut current=root.clone();
        for ordinal in path.split('/').skip(1) {
            let index:usize=ordinal.parse().map_err(|_| "Bad path index")?;
            if index>1024 || started.elapsed()>=Duration::from_millis(timeout_ms) {
                return Err("UIA path bounds or deadline exceeded".into());
            }
            let mut child=unsafe {walker.GetFirstChildElement(&current)}
                .map_err(|_| "Path child not found")?;
            for _ in 0..index {
                if started.elapsed()>=Duration::from_millis(timeout_ms) {
                    return Err("UIA path deadline exceeded".into());
                }
                child=unsafe {walker.GetNextSiblingElement(&child)}
                    .map_err(|_| "Path sibling not found")?;
            }
            current=child;
        }
        Ok::<IUIAutomationElement,Box<dyn Error>>(current)
    }).transpose()?;
    let path_only=direct.is_some();
    let mut stack = vec![Frame { element: direct.unwrap_or(root), path: req["path"].as_str().unwrap_or("0").into() }];
    let mut scanned: usize = 0;
    let mut found: usize = 0;
    let mut samples: Vec<Value> = Vec::new();
    let mut target: Option<IUIAutomationElement> = None;
    let mut interrupted = false;

    while let Some(frame) = stack.pop() {
        if started.elapsed() >= Duration::from_millis(timeout_ms) {
            interrupted = true; break;
        }
        if max_nodes != 0 && scanned >= max_nodes {
            interrupted = true; break;
        }
        scanned += 1;
        if matches(&frame.element, &frame.path, &req) {
            found += 1;
            if samples.len() < 20 { samples.push(label(&frame.element, &frame.path)); }
            if found == 1 { target = Some(frame.element.clone()); }
        }
        if found > 1 { break; } // never act on ambiguous selection
        if path_only { break; } // O(depth), not O(total UIA nodes)

        let mut children: Vec<(IUIAutomationElement, usize)> = Vec::new();
        if let Ok(mut child) = unsafe { walker.GetFirstChildElement(&frame.element) } {
            loop {
                if started.elapsed() >= Duration::from_millis(timeout_ms) {
                    interrupted = true; break;
                }
                let next = unsafe { walker.GetNextSiblingElement(&child) };
                let ordinal = children.len();
                children.push((child, ordinal));
                match next { Ok(s) => child = s, Err(_) => break }
            }
        }
        if interrupted { break; }
        for (child, ordinal) in children.into_iter().rev() {
            stack.push(Frame {
                element: child,
                path: format!("{}/{}", frame.path, ordinal),
            });
        }
    }

    let mut result = json!({
        "schema": "reflexcore.uia.action.v1",
        "timestamp_ms": now_ms()?,
        "nodes_scanned": scanned,
        "match_count": found,
        "matches": samples,
        "status": "not_executed",
        "verification": "not_applicable",
        "scan_complete": !interrupted && found <= 1,
    });
    if interrupted {
        result["status"] = json!("scan_incomplete");
    } else if found == 0 {
        result["status"] = json!("not_found");
    } else if found > 1 {
        result["status"] = json!("ambiguous");
    } else if let Some(ref element) = target {
        result["capabilities"] = capabilities(element);
        if req["action"].as_str() == Some("inspect") {
            result["status"] = json!("inspected");
        } else if matches!(req["action"].as_str(), Some("assert-value" | "assert-name")) {
            match verify_assertion(element, &req) {
                Ok(true) => {
                    result["status"] = json!("assertion_passed");
                    result["verification"] = json!("verified");
                }
                Ok(false) => {
                    result["status"] = json!("assertion_failed");
                    result["verification"] = json!("failed");
                }
                Err(_) => {
                    // Provider failures may contain private UI strings; do not persist them.
                    result["status"] = json!("assertion_error");
                    result["verification"] = json!("unknown");
                }
            }
        } else if req["execute"].as_bool() != Some(true) {
            result["status"] = json!("dry_run");
        } else {
            if crate::task_integrity::cancelled() {
                result["status"] = json!("cancelled");
            } else if fixture_owner.is_some_and(|owner| crate::observer::window_process(target_window) != owner)
                || ((req["require_foreground"] == true || (fixture_owner.is_none() && crate::task_integrity::task_id().is_some()))
                    && crate::observer::foreground_window() != target_window) {
                result["status"] = json!("focus_lost");
            } else {
                match apply(element, req) {
                    Ok(verified) => {
                        result["status"] = json!("issued");
                        result["verification"] = json!(verified);
                    }
                    Err(err) => {
                        result["status"] = json!("action_error");
                        result["error"] = json!(err.to_string());
                    }
                }
            }
        }
    }
    result["duration_ms"] = json!(started.elapsed().as_millis());
    crate::privacy::sanitize_uia_report(&mut result);
    request.payload = result;
    let staging = output.with_extension("tmp");
    fs::OpenOptions::new().write(true).create_new(true).open(&staging)
        .and_then(|mut file| std::io::Write::write_all(&mut file, &serde_json::to_vec(&request)?))?;
    fs::rename(staging, output)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn argv(v: &[&str]) -> Vec<String> { v.iter().map(|s| s.to_string()).collect() }

    #[test]
    fn assert_value_is_read_only_and_accepted() {
        let req = parse(&argv(&["Fixture", "--name=Input", "--action=assert-value", "--value=x"])).unwrap();
        assert!(!req.execute);
        assert_eq!(req.action, "assert-value");
    }

    #[test]
    fn assertion_cannot_request_execute() {
        assert!(parse(&argv(&["Fixture", "--name=Input", "--action=assert-name", "--value=x", "--execute"])).is_err());
    }
    #[test]
    fn needs_unique_selector() {
        assert!(parse(&argv(&["Settings", "--action=focus"])).is_err());
    }
    #[test]
    fn action_must_be_supported() {
        assert!(parse(&argv(&["Settings", "--name=Back", "--action=delete-all"])).is_err());
    }
    #[test]
    fn dry_run_by_default() {
        let req = parse(&argv(&["Settings", "--name=Back", "--action=focus"])).unwrap();
        assert!(!req.execute);
    }
    #[test]
    fn no_fixed_element_count_limit() {
        let req = parse(&argv(&["Settings", "--name=Back", "--max-nodes=0"])).unwrap();
        assert_eq!(req.max_nodes, 0);
    }
    #[test]
    fn path_is_validated() {
        assert!(valid_path("0/1/2"));
        assert!(valid_path("0/0/2"));
        assert!(!valid_path("0/1025"));
        assert!(!valid_path("../2"));
    }
    #[test]
    fn value_requires_explicit_argument() {
        assert!(parse(&argv(&["Settings", "--name=Search", "--action=set-value"])).is_err());
    }
    #[test]
    fn rejects_short_timeout() {
        assert!(parse(&argv(&["Settings", "--name=Back", "--timeout-ms=10"])).is_err());
    }
}
