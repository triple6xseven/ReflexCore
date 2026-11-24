# Local MCP server

The ReflexCore MCP server uses stdio. It reuses the local skill catalog, SQLite movement statistics, and the existing tray queue. The queue supervisor and Rust worker still own execution and verification.

## Start

1. In the Studio sidebar, open **MCP settings** to view connected projects and their full paths. Choose **Add project** to connect an existing folder, **Change folder** to update the selected project, or **Disconnect** to remove its MCP mapping.
2. Switch **MCP On**. A new installation starts off.
3. Register the server once using an absolute launcher path. Open a new client session after changing its configuration.

```powershell
codex mcp add reflexcore -- powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\path\to\ReflexCore\tools\ReflexCore-Mcp.ps1"
```

The server and Studio must use the same ReflexCore installation. The tray must be running to process the queue. Turning MCP off blocks subsequent tool calls, including on an existing connection. Use Studio to stop a pending or running task after switching it off.

## Use

Ask the client to list ReflexCore skills, then check a folder with an existing checklist. For example, submit `folder` as `.`, `checklist` as `checklist.json`, and `report` as `verification.json`. Use `list_projects` to discover the configured projects and pass the selected name as `project`. Paths are relative to that project root. The registry stores references to existing project folders and does not copy the projects. Studio approval is required for every new check, and the report path must be new. Hover a queue row to see its task ID.

Poll `get_task_result` with the submitted task ID. The receipt distinguishes task verification from folder readiness. A verified result can include missing files and zero model calls. The MCP result exposes counts, measurements and reason codes. Detailed filenames and hashes stay in the local report. Cancellation requests and terminal cancellation are separate outcomes.

The client can use the catalog, verifier descriptions, movement statistics and typed task outcomes to improve skill selection in future requests. This bridge adds no new trainer. The existing learning mode continues to govern experimental training.

## Test

```powershell
cargo build --release --locked
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tasks\Test-Handoff.ps1 -Mcp
```

The fixture covers stdio initialization, tool discovery, the off switch, scope rejection, approval, an independently reopened report, a matched terminal receipt and cancellation before execution.
