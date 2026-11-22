//! Default-private persistence policy.
//! The live UIA engine may use names and automation IDs transiently in memory.
//! Persisted reports intentionally omit those strings, keeping geometry,
//! control types, tree paths and nontextual state for debugging.

use serde_json::Value;

const MASK: &str = "[private]";

fn redact_field(value: &mut Value, field: &str) {
    if let Some(Value::String(text)) = value.get_mut(field) {
        if !text.is_empty() {
            *text = MASK.to_owned();
        }
    }
}

pub fn sanitize_uia_report(value: &mut Value) {
    // No UIA label, account display name or selector string reaches disk.
    // UI actions still match against original names before serialization.
    redact_field(value, "window_title");
    if let Some(nodes) = value.get_mut("nodes").and_then(Value::as_array_mut) {
        for node in nodes {
            redact_field(node, "name");
            redact_field(node, "automation_id");
        }
    }
    if let Some(matches) = value.get_mut("matches").and_then(Value::as_array_mut) {
        for element in matches {
            redact_field(element, "name");
            redact_field(element, "automation_id");
        }
    }
    // COM error descriptions normally contain HRESULTs only. Suppress them if
    // a provider returns what looks like a path or an email address.
    if let Some(Value::String(message)) = value.get_mut("error") {
        if message.contains('@') || message.contains("\\Users\\") || message.contains("/Users/") {
            *message = "[private error text]".to_owned();
        }
    }
}

fn sanitize_window(window: &mut Value) {
    redact_field(window, "title");
}

pub fn sanitize_window_report(value: &mut Value) {
    if let Some(windows) = value.get_mut("windows").and_then(Value::as_array_mut) {
        for window in windows {
            sanitize_window(window);
        }
    }
}

pub fn sanitize_window_diff(value: &mut Value) {
    for key in ["added", "removed"] {
        if let Some(windows) = value.get_mut(key).and_then(Value::as_array_mut) {
            for window in windows {
                sanitize_window(window);
            }
        }
    }
    if let Some(changed) = value.get_mut("changed").and_then(Value::as_array_mut) {
        for entry in changed {
            if let Some(before) = entry.get_mut("before") { sanitize_window(before); }
            if let Some(after) = entry.get_mut("after") { sanitize_window(after); }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn ui_labels_do_not_reach_reports() {
        let mut report = json!({
            "nodes": [{"name": "Private Person", "automation_id": "user@example.test", "path": "0/1", "control_type": "button"}],
            "matches": [{"name": "Private Person", "automation_id": "account-id", "type": "button"}],
            "window_title": "Private Document"
        });
        sanitize_uia_report(&mut report);
        assert_eq!(report["nodes"][0]["name"], MASK);
        assert_eq!(report["nodes"][0]["automation_id"], MASK);
        assert_eq!(report["matches"][0]["name"], MASK);
        assert_eq!(report["window_title"], MASK);
        assert_eq!(report["nodes"][0]["path"], "0/1");
        assert_eq!(report["nodes"][0]["control_type"], "button");
    }

    #[test]
    fn window_titles_are_private() {
        let mut observation = json!({"windows": [{"title": "Personal File", "pid": 99}]});
        sanitize_window_report(&mut observation);
        assert_eq!(observation["windows"][0]["title"], MASK);
        assert_eq!(observation["windows"][0]["pid"], 99);
    }

    #[test]
    fn window_diff_titles_are_private() {
        let mut report = json!({
            "added": [{"title": "Account Name"}],
            "removed": [{"title": "Secret"}],
            "changed": [{"before": {"title": "Old"}, "after": {"title": "New"}}]
        });
        sanitize_window_diff(&mut report);
        assert_eq!(report["added"][0]["title"], MASK);
        assert_eq!(report["removed"][0]["title"], MASK);
        assert_eq!(report["changed"][0]["before"]["title"], MASK);
        assert_eq!(report["changed"][0]["after"]["title"], MASK);
    }
}