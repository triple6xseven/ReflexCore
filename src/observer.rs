use serde::Serialize;
use std::{
    error::Error,
    ffi::c_void,
    fs,
    time::{Instant, SystemTime, UNIX_EPOCH},
};

type Result<T> = std::result::Result<T, Box<dyn Error>>;
type Hwnd = *mut c_void;

#[repr(C)]
#[derive(Default)]
struct Rect {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
}

#[link(name = "user32")]
unsafe extern "system" {
    fn EnumWindows(
        callback: Option<unsafe extern "system" fn(Hwnd, isize) -> i32>,
        param: isize,
    ) -> i32;
    fn IsWindowVisible(hwnd: Hwnd) -> i32;
    fn GetWindowTextLengthW(hwnd: Hwnd) -> i32;
    fn GetWindowTextW(hwnd: Hwnd, text: *mut u16, max: i32) -> i32;
    fn GetWindowThreadProcessId(hwnd: Hwnd, pid: *mut u32) -> u32;
    fn GetWindowRect(hwnd: Hwnd, rect: *mut Rect) -> i32;
    fn GetForegroundWindow() -> Hwnd;

}

#[link(name="dwmapi")]
unsafe extern "system" {
    fn DwmGetWindowAttribute(hwnd:Hwnd, attribute:u32, value:*mut u32, size:u32) -> i32;
}

#[derive(Debug, Serialize)]
pub struct WindowInfo {
    hwnd: String,
    pid: u32,
    title: String,
    active: bool,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
}

#[derive(Serialize)]
struct Observation {
    timestamp_ms: u128,
    capture_us: u128,
    window_count: usize,
    windows: Vec<WindowInfo>,
}

struct ScanContext {
    windows: Vec<WindowInfo>,
    foreground: Hwnd,
}

// The callback is called synchronously during enumeration.
// No pointer escapes the lifetime of scan_windows().
unsafe extern "system" fn collect_window(hwnd: Hwnd, param: isize) -> i32 {
    if IsWindowVisible(hwnd) == 0 {return 1;}
    // DWMWA_CLOAKED=14: don't treat invisible UWP/Desktop windows as visible UI.
    let mut cloaked=0u32;
    if DwmGetWindowAttribute(hwnd,14,&mut cloaked,4)==0 && cloaked!=0 {return 1;}
    let len = GetWindowTextLengthW(hwnd);
    if len <= 0 {
        return 1;
    }

    // Guard allocations for titles supplied by other processes.
    let capacity = (len as usize).min(4096) + 1;
    let mut buffer = vec![0u16; capacity];
    let copied = GetWindowTextW(hwnd, buffer.as_mut_ptr(), capacity as i32);
    if copied <= 0 {
        return 1;
    }
    let title = String::from_utf16_lossy(&buffer[..copied as usize]);
    if title.trim().is_empty() {
        return 1;
    }

    let mut pid = 0u32;
    GetWindowThreadProcessId(hwnd, &mut pid);

    let mut rect = Rect::default();
    if GetWindowRect(hwnd, &mut rect) == 0 {
        return 1;
    }

    let context = &mut *(param as *mut ScanContext);
    context.windows.push(WindowInfo {
        hwnd: format!("0x{:X}", hwnd as usize),
        pid,
        title,
        active: hwnd == context.foreground,
        x: rect.left,
        y: rect.top,
        width: rect.right.saturating_sub(rect.left),
        height: rect.bottom.saturating_sub(rect.top),
    });
    1
}

fn scan_windows() -> Result<Observation> {
    let start = Instant::now();
    let mut context = ScanContext {
        windows: Vec::with_capacity(64),
        foreground: foreground_window(),
    };

    let success = unsafe {
        EnumWindows(
            Some(collect_window),
            (&mut context as *mut ScanContext) as isize,
        )
    };
    if success == 0 {
        return Err(std::io::Error::last_os_error().into());
    }

    let elapsed = start.elapsed().as_micros();
    let timestamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_millis();
    Ok(Observation {
        timestamp_ms: timestamp,
        capture_us: elapsed,
        window_count: context.windows.len(),
        windows: context.windows,
    })
}

pub fn show(filter: Option<&str>, save: bool) -> Result<()> {
    let mut observation = scan_windows()?;
    if let Some(query) = filter {
        let query = query.to_lowercase();
        observation.windows.retain(|w| w.title.to_lowercase().contains(&query));
    }
    observation.window_count = observation.windows.len();
    let mut safe = serde_json::to_value(&observation)?;
    crate::privacy::sanitize_window_report(&mut safe);
    let output = serde_json::to_string_pretty(&safe)?;
    if save {
        fs::create_dir_all("data")?;
        fs::write("data/windows_snapshot.json", &output)?;
        eprintln!("Snapshot saved: data/windows_snapshot.json");
    }
    println!("{output}");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn observer_returns_consistent_count() {
        let result = scan_windows().unwrap();
        assert_eq!(result.window_count, result.windows.len());
    }

    #[test]
    fn observer_json_is_valid() {
        let result = scan_windows().unwrap();
        let encoded = serde_json::to_string(&result).unwrap();
        let value: serde_json::Value = serde_json::from_str(&encoded).unwrap();
        assert!(value["windows"].is_array());
    }
}

// Expose a read-only observation to other ReflexCore modules.
// No Windows actions are performed here.
pub fn capture_value() -> Result<serde_json::Value> {
    let observation = scan_windows()?;
    Ok(serde_json::to_value(observation)?)
}

pub(crate) fn foreground_window() -> Hwnd { unsafe { GetForegroundWindow() } }

pub(crate) fn window_process(hwnd: Hwnd) -> u32 {
    let mut pid = 0;
    unsafe { GetWindowThreadProcessId(hwnd, &mut pid); }
    pid
}
