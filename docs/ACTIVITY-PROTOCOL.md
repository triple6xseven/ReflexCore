# Activity v1 — private, enum-only status interface

**Writer(s):** `tools/ReflexGame-RustBridge.cs` for Citadel, `tools/ReflexCore-SharedControl.cs` for Qwen + Windows navigation.
**Reader:** `tools/ReflexCore-Tray.cs` (existing single-instance tray).
**Path:** `%LOCALAPPDATA%/ReflexCore/runtime/activity.json`; never commit or upload.
**Schema:** `reflexcore.activity.v1`.
**Fields:** `schema`, `source`, `stage`, `action`, `sequence`, `elapsed_ms`, `at_utc`.
**Sources:** `citadel_rust`, `shared_control`.
**Stages:** `ready`, `observing`, `capturing`, `thinking`, `deciding`, `awaiting_effect`, `executing`, `verifying`, `verified`, `human_override`, `completed`, `failed`, `stopped`.
**Actions:** `none`, `deploy`, `skill`, `focus`; never untrusted raw text.
**Freshness:** tray rejects invalid/stale messages older than 65 seconds or 10 seconds in the future; it shows job state otherwise.
**Safety:** purely observational file, never a command channel. Tray must not infer that `verified` proves OS-level motion; it only reflects corresponding producer's evidence. Tray status is not authorization to send input.
**Concurrency:** last writer wins (single snapshot). This is intentionally v1; future version should use per-source records if simultaneous sessions are supported.
**Privacy:** no usernames, screenshots, coordinates, prompt bodies, UI texts, model outputs, window titles or secrets. Avoid personal paths in logs or version control.
**Notifications:** only on meaningful stage transitions; do not flood on each frame.
