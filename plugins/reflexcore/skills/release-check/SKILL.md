---
name: release-check
description: Use the configured ReflexCore MCP server to check a local project's release folder, monitor an existing check, or interpret its verified receipt. On Windows, supports configured projects such as ReflexCore and zxcLagLab.
---

Call `list_projects` to resolve the requested project and its saved presets. For a release check, choose the configured release preset. If choices are ambiguous, list them and ask which to use. Submit with `submit_saved_handoff` once and retain the returned task ID.

When `next_action` is `approve_in_studio`, tell the operator which project and preset are awaiting approval in Studio. Keep the ID for `get_task_result` after approval. During a running task use bounded, spaced status checks. Avoid resubmitting while results are pending. Request cancellation only when the operator asks, and report it as confirmed only after a terminal cancelled receipt.

Report task verification and folder readiness separately. Call a check verified only when its receipt says verified. A verified receipt can still report missing files. Counts are available in the receipt. The detailed report stays local and is opened in Studio.

The plugin uses the installed `reflexcore` MCP connection. If unavailable, explain how to enable it in ReflexCore Studio. A saved check requires a preset; a request with explicit file inputs can instead use `submit_handoff_check` with paths relative to the selected project.
