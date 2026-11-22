use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    error::Error,
    fs,
    path::Path,
};

type Result<T> = std::result::Result<T, Box<dyn Error>>;

const BASELINE: &str = "data/windows_snapshot.json";

fn index_windows(snapshot: &Value) -> Result<BTreeMap<String, Value>> {
    let windows = snapshot
        .get("windows")
        .and_then(Value::as_array)
        .ok_or("Invalid snapshot: windows array missing")?;

    let mut index = BTreeMap::new();

    for window in windows {
        let hwnd = window
            .get("hwnd")
            .and_then(Value::as_str)
            .ok_or("Invalid snapshot: window handle missing")?;

        if index.insert(hwnd.to_owned(), window.clone()).is_some() {
            return Err("Invalid snapshot: duplicate window handle".into());
        }
    }

    Ok(index)
}

// Pure deterministic comparison: no Windows API calls.
// A repeated HWND is treated as the same tracked window.
fn compare(previous: &Value, current: &Value) -> Result<Value> {
    let old_index = index_windows(previous)?;
    let new_index = index_windows(current)?;

    let mut added = Vec::new();
    let mut removed = Vec::new();
    let mut changed = Vec::new();

    for (hwnd, new_window) in &new_index {
        match old_index.get(hwnd) {
            None => added.push(new_window.clone()),

            Some(old_window) => {
                let fields: Vec<&str> = [
                    "pid",
                    "title",
                    "active",
                    "x",
                    "y",
                    "width",
                    "height",
                ]
                .into_iter()
                .filter(|field| {
                    old_window.get(*field) != new_window.get(*field)
                })
                .collect();

                if !fields.is_empty() {
                    changed.push(json!({
                        "hwnd": hwnd,
                        "fields": fields,
                        "before": old_window,
                        "after": new_window
                    }));
                }
            }
        }
    }

    for (hwnd, old_window) in &old_index {
        if !new_index.contains_key(hwnd) {
            removed.push(old_window.clone());
        }
    }

    let added_count = added.len();
    let removed_count = removed.len();
    let changed_count = changed.len();

    Ok(json!({
        "baseline_timestamp_ms": previous["timestamp_ms"],
        "current_timestamp_ms": current["timestamp_ms"],
        "baseline_window_count": old_index.len(),
        "current_window_count": new_index.len(),
        "summary": {
            "added": added_count,
            "removed": removed_count,
            "changed": changed_count
        },
        "added": added,
        "removed": removed,
        "changed": changed
    }))
}

pub fn run() -> Result<()> {
    if !Path::new(BASELINE).is_file() {
        return Err(
            "No baseline snapshot. Run 'cargo run -- snapshot' first.".into()
        );
    }

    let mut previous: Value = serde_json::from_slice(
        &fs::read(BASELINE)?
    )?;

    let mut current = crate::observer::capture_value()?;

    crate::privacy::sanitize_window_report(&mut previous);
    crate::privacy::sanitize_window_report(&mut current);
    let mut report = compare(&previous, &current)?;
    crate::privacy::sanitize_window_diff(&mut report);

    println!("{}", serde_json::to_string_pretty(&report)?);

    // The baseline is intentionally NOT overwritten.
    // This command is read-only.
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn window(hwnd: &str, x: i32, active: bool) -> Value {
        json!({
            "hwnd": hwnd,
            "pid": 100,
            "title": "Test window",
            "active": active,
            "x": x,
            "y": 0,
            "width": 800,
            "height": 600
        })
    }

    fn snapshot(windows: Vec<Value>) -> Value {
        json!({
            "timestamp_ms": 1234,
            "windows": windows
        })
    }

    #[test]
    fn detects_added_removed_and_changed_windows() {
        let previous = snapshot(vec![
            window("0xA", 0, false),
            window("0xB", 0, false),
        ]);

        let current = snapshot(vec![
            window("0xB", 50, true),
            window("0xC", 0, false),
        ]);

        let diff = compare(&previous, &current).unwrap();

        assert_eq!(diff["summary"]["added"], 1);
        assert_eq!(diff["summary"]["removed"], 1);
        assert_eq!(diff["summary"]["changed"], 1);

        let fields = diff["changed"][0]["fields"]
            .as_array()
            .unwrap();

        assert!(fields.contains(&json!("x")));
        assert!(fields.contains(&json!("active")));
    }

    #[test]
    fn identical_snapshots_have_no_changes() {
        let a = snapshot(vec![window("0xA", 0, true)]);
        let b = snapshot(vec![window("0xA", 0, true)]);

        let diff = compare(&a, &b).unwrap();

        assert_eq!(diff["summary"]["added"], 0);
        assert_eq!(diff["summary"]["removed"], 0);
        assert_eq!(diff["summary"]["changed"], 0);
    }

    #[test]
    fn invalid_snapshot_is_rejected() {
        let invalid = json!({"wrong_field": []});
        let valid = snapshot(vec![]);

        assert!(compare(&invalid, &valid).is_err());
    }
}