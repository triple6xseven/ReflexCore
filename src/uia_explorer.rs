//! ReflexCore 0.0.4: native Windows UI Automation tree explorer.
//! UI Automation COM calls are executed in a disposable worker process.
//! The CLI parent supervises the worker and enforces a wall-clock timeout.

use serde::Serialize;
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
    Win32::{
        Foundation::HWND,
        System::Com::{
            CoCreateInstance, CoInitializeEx, CoUninitialize,
            CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED,
        },
        UI::Accessibility::{
            CUIAutomation, IUIAutomation, IUIAutomationElement,
            IUIAutomationTreeWalker,
        },
    },
};

type Result<T> = std::result::Result<T, Box<dyn Error>>;

#[derive(Debug, Clone)]
struct Options {
    selector: Option<String>,
    hwnd: Option<usize>,
    view: String,
    max_nodes: usize,
    max_depth: usize,
    timeout_ms: u64,
    print_all: bool,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            selector: None,
            hwnd: None,
            view: "raw".into(),
            max_nodes: 20_000,
            max_depth: 0, // 0 means unlimited
            timeout_ms: 30_000,
            print_all: false,
        }
    }
}

fn parse_hwnd(value: &str) -> Result<usize> {
    let value = value.trim();
    let digits = value
        .strip_prefix("0x")
        .or_else(|| value.strip_prefix("0X"))
        .unwrap_or(value);
    Ok(usize::from_str_radix(digits, 16)?)
}

fn parse_options(args: &[String]) -> Result<Options> {
    let mut options = Options::default();

    for arg in args {
        if arg == "--active" {
            options.selector = None;
        } else if arg == "--print-all" {
            options.print_all = true;
        } else if let Some(value) = arg.strip_prefix("--hwnd=") {
            options.hwnd = Some(parse_hwnd(value)?);
        } else if let Some(value) = arg.strip_prefix("--view=") {
            if !matches!(value, "raw" | "control" | "content") {
                return Err("--view must be raw, control, or content".into());
            }
            options.view = value.to_owned();
        } else if let Some(value) = arg.strip_prefix("--max-nodes=") {
            options.max_nodes = value.parse()?;
        } else if let Some(value) = arg.strip_prefix("--max-depth=") {
            options.max_depth = value.parse()?;
        } else if let Some(value) = arg.strip_prefix("--timeout-ms=") {
            options.timeout_ms = value.parse()?;
            if options.timeout_ms < 100 {
                return Err("--timeout-ms must be at least 100".into());
            }
        } else if arg.starts_with('-') {
            return Err(format!("Unknown UIA option: {arg}").into());
        } else if options.selector.is_none() {
            options.selector = Some(arg.to_owned());
        } else {
            return Err("Provide one window title, or --active, or --hwnd=0x...".into());
        }
    }
    Ok(options)
}

fn find_window(options: &Options) -> Result<(usize, String)> {
    let snapshot = crate::observer::capture_value()?;
    let windows = snapshot["windows"]
        .as_array()
        .ok_or("Window observer returned no windows array")?;

    if let Some(hwnd) = options.hwnd {
        let matched = windows.iter().find(|w| {
            w["hwnd"].as_str()
                .and_then(|s| parse_hwnd(s).ok()) == Some(hwnd)
        });
        let title = matched
            .and_then(|w| w["title"].as_str())
            .ok_or("Specified HWND is not a visible observed window")?;
        return Ok((hwnd, title.to_owned()));
    }

    let target = options.selector.as_ref().map(|s| s.to_lowercase());

    let mut matches: Vec<&Value> = windows.iter().filter(|window| {
        match &target {
            Some(query) => window["title"]
                .as_str()
                .is_some_and(|s| s.to_lowercase().contains(query.as_str())),
            None => window["active"].as_bool() == Some(true),
        }
    }).collect();

    matches.sort_by_key(|w| {
        let active = w["active"].as_bool().unwrap_or(false);
        let exact = target.as_ref().is_some_and(|query| {
            w["title"].as_str().is_some_and(|s| s.to_lowercase().as_str() == query.as_str())
        });
        (!exact, !active)
    });

    let selected = matches.first().ok_or(
        "No matching window. Try: cargo run -- windows"
    )?;
    let handle = parse_hwnd(selected["hwnd"].as_str().ok_or("Missing HWND")?)?;
    let title = selected["title"].as_str().unwrap_or("").to_owned();
    Ok((handle, title))
}

fn unix_ms() -> Result<u128> {
    Ok(SystemTime::now().duration_since(UNIX_EPOCH)?.as_millis())
}

pub fn run(args: &[String]) -> Result<()> {
    let options = parse_options(args)?;
    let (hwnd, _title) = find_window(&options)?;
    let temp = std::env::temp_dir().join(format!(
        "reflexcore-uia-{}-{}.json",
        std::process::id(), unix_ms()?
    ));

    let exe = std::env::current_exe()?;
    let mut child = Command::new(exe)
        .arg("uia-worker")
        .arg(hwnd.to_string())
        .arg(&temp)
        .arg(&options.view)
        .arg(options.max_nodes.to_string())
        .arg(options.max_depth.to_string())
        .arg(options.timeout_ms.to_string())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()?;

    let limit = Duration::from_millis(options.timeout_ms.saturating_add(1000));
    let started = Instant::now();
    let exit_status;
    loop {
        if let Some(status) = child.try_wait()? {
            exit_status = status;
            break;
        }
        if started.elapsed() >= limit {
            let _ = child.kill();
            let _ = child.wait();
            let _ = fs::remove_file(&temp);
            return Err(format!(
                "UI Automation worker timed out after {} ms; worker terminated",
                limit.as_millis()
            ).into());
        }
        thread::sleep(Duration::from_millis(25));
    }

    if !exit_status.success() {
        let _ = fs::remove_file(&temp);
        let mut details = String::new();
        if let Some(mut stderr) = child.stderr.take() {
            let _ = stderr.read_to_string(&mut details);
        }
        return Err(format!("UI Automation worker failed: {exit_status}. {}", details.trim()).into());
    }

    let bytes = fs::read(&temp)?;
    let _ = fs::remove_file(&temp);
    let report: Value = serde_json::from_slice(&bytes)?;

    fs::create_dir_all("data")?;
    fs::write("data/uia_snapshot.json", &bytes)?;

    println!("ReflexCore UIA Explorer 0.0.4");
    println!("Window: [private window] [0x{hwnd:X}]");
    println!("View: {} | Nodes: {} | Truncated: {} | Reason: {} | Capture: {} ms",
        options.view,
        report["node_count"], report["truncated"],
        report["stop_reason"], report["capture_ms"]);
    println!("Full tree: data/uia_snapshot.json");

    let nodes = report["nodes"].as_array().ok_or("Worker returned invalid nodes")?;
    if options.print_all {
        println!("{}", serde_json::to_string_pretty(&report)?);
    } else {
        println!("Showing first {} nodes (use --print-all for complete JSON):",
            nodes.len().min(25));
        for node in nodes.iter().take(25) {
            let depth = node["depth"].as_u64().unwrap_or(0).min(20) as usize;
            let kind = node["control_type"].as_str().unwrap_or("?");
            let name = node["name"].as_str().unwrap_or("");
            println!("{}[{}] {} {:?}", "  ".repeat(depth),
                node["index"], kind, name);
        }
    }
    Ok(())
}

struct ComApartment;
impl ComApartment {
    fn enter() -> windows::core::Result<Self> {
        unsafe { CoInitializeEx(None, COINIT_MULTITHREADED).ok()?; }
        Ok(Self)
    }
}
impl Drop for ComApartment {
    fn drop(&mut self) {
        unsafe { CoUninitialize(); }
    }
}

#[derive(Serialize)]
struct ElementInfo {
    index: usize,
    parent: Option<usize>,
    depth: usize,
    path: String,
    process_id: Option<i32>,
    control_type_id: Option<i32>,
    control_type: Option<String>,
    name: Option<String>,
    automation_id: Option<String>,
    class_name: Option<String>,
    framework_id: Option<String>,
    enabled: Option<bool>,
    offscreen: Option<bool>,
    focused: Option<bool>,
    password: Option<bool>,
    bounds: Option<[i32; 4]>,
}

struct Pending {
    element: IUIAutomationElement,
    parent: Option<usize>,
    depth: usize,
    path: String,
}

fn clip(s: String) -> String {
    s.chars().take(2048).collect()
}

fn describe(element: &IUIAutomationElement, index: usize, frame: &Pending) -> ElementInfo {
    // Password values are never read. Other UIA names can still be sensitive;
    // the local snapshot is not transmitted anywhere by ReflexCore.
    let password = unsafe { element.CurrentIsPassword() }.ok().map(|v| v.as_bool());
    let name = if password == Some(true) {
        Some("[password element]".to_owned())
    } else {
        unsafe { element.CurrentName() }.ok().map(|v| clip(v.to_string()))
    };
    let control_type_id = unsafe { element.CurrentControlType() }.ok().map(|v| v.0);
    let bounds = unsafe { element.CurrentBoundingRectangle() }.ok().map(|r| {
        [r.left, r.top, r.right.saturating_sub(r.left), r.bottom.saturating_sub(r.top)]
    });
    ElementInfo {
        index,
        parent: frame.parent,
        depth: frame.depth,
        path: frame.path.clone(),
        process_id: unsafe { element.CurrentProcessId() }.ok(),
        control_type_id,
        control_type: unsafe { element.CurrentLocalizedControlType() }.ok()
            .map(|v| clip(v.to_string())),
        name,
        automation_id: unsafe { element.CurrentAutomationId() }.ok()
            .map(|v| clip(v.to_string())),
        class_name: unsafe { element.CurrentClassName() }.ok()
            .map(|v| clip(v.to_string())),
        framework_id: unsafe { element.CurrentFrameworkId() }.ok()
            .map(|v| clip(v.to_string())),
        enabled: unsafe { element.CurrentIsEnabled() }.ok().map(|v| v.as_bool()),
        offscreen: unsafe { element.CurrentIsOffscreen() }.ok().map(|v| v.as_bool()),
        focused: unsafe { element.CurrentHasKeyboardFocus() }.ok().map(|v| v.as_bool()),
        password,
        bounds,
    }
}

fn walker_for(automation: &IUIAutomation, view: &str) -> windows::core::Result<IUIAutomationTreeWalker> {
    unsafe {
        match view {
            "control" => automation.ControlViewWalker(),
            "content" => automation.ContentViewWalker(),
            _ => automation.RawViewWalker(),
        }
    }
}

// Executed ONLY in a dedicated child process. The parent can terminate this
// process if a third-party UI Automation provider gets stuck in a COM call.
pub fn run_worker(args: &[String]) -> Result<()> {
    if args.len() != 6 {
        return Err("Invalid internal worker arguments".into());
    }
    let hwnd: usize = args[0].parse()?;
    let output = PathBuf::from(&args[1]);
    let view = &args[2];
    let max_nodes: usize = args[3].parse()?;
    let max_depth: usize = args[4].parse()?;
    let timeout_ms: u64 = args[5].parse()?;

    let _com = ComApartment::enter()?;
    let started = Instant::now();
    let automation: IUIAutomation = unsafe {
        CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER)?
    };
    let root = unsafe { automation.ElementFromHandle(HWND(hwnd as *mut c_void))? };
    let walker = walker_for(&automation, view)?;

    let mut pending = vec![Pending {
        element: root,
        parent: None,
        depth: 0,
        path: "0".to_owned(),
    }];
    let mut nodes: Vec<ElementInfo> = Vec::new();
    let mut stop_reason: Option<&str> = None;

    while let Some(frame) = pending.pop() {
        if started.elapsed() >= Duration::from_millis(timeout_ms) {
            stop_reason = Some("time_budget");
            break;
        }
        if max_nodes > 0 && nodes.len() >= max_nodes {
            stop_reason = Some("node_budget");
            break;
        }

        let index = nodes.len();
        nodes.push(describe(&frame.element, index, &frame));

        if max_depth > 0 && frame.depth >= max_depth {
            stop_reason.get_or_insert("depth_budget");
            continue;
        }

        let mut children: Vec<(IUIAutomationElement, usize)> = Vec::new();
        if let Ok(mut child) = unsafe { walker.GetFirstChildElement(&frame.element) } {
            loop {
                if started.elapsed() >= Duration::from_millis(timeout_ms) {
                    stop_reason = Some("time_budget");
                    break;
                }
                if max_nodes > 0 && nodes.len() + pending.len() + children.len() >= max_nodes {
                    stop_reason = Some("node_budget");
                    break;
                }
                let ordinal = children.len();
                let next = unsafe { walker.GetNextSiblingElement(&child) };
                children.push((child, ordinal));
                match next {
                    Ok(sibling) => child = sibling,
                    Err(_) => break,
                }
            }
        }
        for (element, ordinal) in children.into_iter().rev() {
            pending.push(Pending {
                element,
                parent: Some(index),
                depth: frame.depth.saturating_add(1),
                path: format!("{}/{}", frame.path, ordinal),
            });
        }
        if stop_reason == Some("time_budget") || stop_reason == Some("node_budget") {
            break;
        }
    }

    let mut report = json!({
        "schema": "reflexcore.uia.v1",
        "timestamp_ms": unix_ms()?,
        "hwnd": format!("0x{hwnd:X}"),
        "view": view,
        "node_count": nodes.len(),
        "capture_ms": started.elapsed().as_millis(),
        "truncated": stop_reason.is_some(),
        "stop_reason": stop_reason,
        "nodes": nodes
    });
    crate::privacy::sanitize_uia_report(&mut report);
    fs::write(output, serde_json::to_vec_pretty(&report)?)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_handle_is_hexadecimal() {
        assert_eq!(parse_hwnd("0x2A").unwrap(), 42);
        assert_eq!(parse_hwnd("2A").unwrap(), 42);
    }

    #[test]
    fn invalid_view_rejected() {
        let result = parse_options(&["--view=wrong".into()]);
        assert!(result.is_err());
    }

    #[test]
    fn depth_and_node_limits_are_configurable() {
        let options = parse_options(&[
            "Settings".into(),
            "--max-nodes=0".into(),
            "--max-depth=0".into(),
            "--timeout-ms=60000".into(),
        ]).unwrap();
        assert_eq!(options.max_nodes, 0);
        assert_eq!(options.max_depth, 0);
        assert_eq!(options.timeout_ms, 60000);
    }

    #[test]
    fn too_short_timeout_rejected() {
        assert!(parse_options(&["--timeout-ms=0".into()]).is_err());
    }
}
