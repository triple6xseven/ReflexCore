use super::*;
use std::{
    process::{Command, Stdio},
    thread,
    time::Duration,
};

#[test]
fn controlled_worker() {
    if std::env::var_os("HANDOFF_TEST_STAGE").is_some() {
        let _ = run(&["--queued".into()]);
    }
}

// The parent process holds the writer, edits the staged artifact, or cancels
// the live claim. Only the test binary contains the synchronization barrier.
fn interrupt(case: &str) {
    let dir = std::env::temp_dir().join(format!("ReflexHandoff-{}", task_integrity::run_id()));
    let id = "20260101000000000-0123456789abcdef0123456789abcdef";
    for sub in [
        "data/bridge/running",
        "data/bridge/queue-requests",
        "data/private/handoff",
        "folder",
    ] {
        fs::create_dir_all(dir.join(sub)).unwrap();
    }
    let payload = dir.join("folder/example");
    let mut writer = OpenOptions::new()
        .write(true)
        .create_new(true)
        .share_mode(3)
        .open(&payload)
        .unwrap();
    writer.write_all(&[1; 131072]).unwrap();
    let mut writer = Some(writer);
    if case != "changed" {
        drop(writer.take())
    }
    let checklist = dir.join("checklist.json");
    let report = dir.join("report.json");
    fs::write(
        &checklist,
        json!({"schema":"reflexcore.handoff.checklist.v1","name":"Synthetic",
        "files":[{"path":"example","sha256":"0".repeat(64)}]})
        .to_string(),
    )
    .unwrap();
    fs::write(
        dir.join(format!("data/private/handoff/{id}.json")),
        json!({
        "folder":dir.join("folder"),"checklist":checklist,"report":report})
        .to_string(),
    )
    .unwrap();
    fs::write(
        dir.join(format!("data/bridge/running/{id}.job")),
        "RUN\nverify-handoff.ps1",
    )
    .unwrap();
    let stage = match case {
        "changed" => "sampled",
        "cancel_read" => "hashing",
        _ => "staged",
    };
    let mut child = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "handoff::tests::controlled_worker"])
        .env("REFLEXCORE_QUEUE_MANIFEST", format!("{id}.job"))
        .env("HANDOFF_TEST_STAGE", stage)
        .current_dir(&dir)
        .stdout(Stdio::null())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(15);
    while !dir.join("reached").exists() {
        assert!(
            child.try_wait().unwrap().is_none() && Instant::now() < deadline,
            "worker missed {stage}"
        );
        thread::sleep(Duration::from_millis(5));
    }
    let staged = dir.join(format!(".reflex-handoff-{id}.tmp"));
    match case {
        "changed" => {
            writer.as_mut().unwrap().write_all(&[2; 16]).unwrap();
            drop(writer.take());
        }
        "cancel_read" | "cancel_publish" => fs::write(
            dir.join(format!("data/bridge/queue-requests/{id}.cancel")),
            "",
        )
        .unwrap(),
        "corrupt" => fs::write(&staged, b"{").unwrap(),
        "stale" | "findings" => {
            let mut doc: serde_json::Value =
                serde_json::from_slice(&fs::read(&staged).unwrap()).unwrap();
            if case == "stale" {
                doc["run_id"] = json!("previous");
            } else {
                doc["results"][0]["status"] = json!("present");
            }
            fs::write(&staged, doc.to_string()).unwrap();
        }
        "collision" => fs::write(&report, "existing").unwrap(),
        _ => unreachable!(),
    }
    fs::write(dir.join("resume"), "").unwrap();
    assert!(child.wait().unwrap().success());
    let receipt: serde_json::Value = serde_json::from_slice(
        &fs::read(dir.join(format!("data/bridge/running/{id}.receipt.json"))).unwrap(),
    )
    .unwrap();
    assert_eq!(receipt["run_id"], id);
    assert_eq!(receipt["metrics"]["model_calls"], 0);
    match case {
        "changed" => {
            assert_eq!(receipt["outcome"], "unverified");
            let r: Report = serde_json::from_slice(&fs::read(&report).unwrap()).unwrap();
            assert_eq!(r.results[0].status, Status::Changed);
            assert_eq!(r.verdict, "Needs attention");
        }
        "collision" => {
            assert_eq!(receipt["outcome"], "failed");
            assert_eq!(fs::read(&report).unwrap(), b"existing");
        }
        _ => {
            assert!(!report.exists());
            assert_eq!(
                receipt["reason"],
                if case.starts_with("cancel") {
                    "operator_cancelled"
                } else {
                    "verification_failed"
                }
            );
        }
    }
    assert!(!staged.exists());
    fs::remove_dir_all(dir).unwrap();
}
#[test]
fn changed_during_check() {
    interrupt("changed")
}
#[test]
fn cancelled_during_hash() {
    interrupt("cancel_read")
}
#[test]
fn cancelled_before_publish() {
    interrupt("cancel_publish")
}
#[test]
fn corrupt_report() {
    interrupt("corrupt")
}
#[test]
fn stale_report() {
    interrupt("stale")
}
#[test]
fn unrelated_findings() {
    interrupt("findings")
}
#[test]
fn destination_race() {
    interrupt("collision")
}
