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

Ask Codex to check a local project's release folder. The client calls `list_projects`, selects a saved preset, and submits it through `submit_saved_handoff`. The current task ID is shown in Studio as a queue-row tooltip. Selecting the pending row shows its folder and checklist name. Approve the specific check in Studio. The server exposes no approval tool.

Saved presets are private installation settings. In `data/settings/mcp-handoff-presets.json`, map each project name to a preset name and a project-relative folder. For example, `{"zxclaglab":{"release":"artifacts/portable"}}`. Put the typed checklist at `data/private/mcp-checklists/zxclaglab.release.json`. The queue binds the requested checklist digest at submission. Reports use new names under `data/private/mcp-reports`. Existing projects are used in place.

Explicit checks still use `submit_handoff_check` with `folder`, `checklist`, and `report` relative to the selected project. `get_task_result` returns the next operator step, a workflow version, the typed receipt and a separate folder verdict. Verified checks may report missing items. Filenames and hashes stay in the local report. Cancellation requests and completed cancellation are separate outcomes.

`list_skills` exposes the executable workflow separately from the experimental movement catalog. It distinguishes missing memory from an empty replay history and groups retained handoff receipts by verified, cancelled, interrupted and other unverified outcomes. The optional `data/settings/mcp-memory-root.txt` selects another local ReflexCore installation for read-only SQLite access. Values and paths stay local. The bridge does not add a trainer or share observations between incompatible workflows.

## Local Codex plugin

ReflexCore ships a local plugin catalog with release-check and offline-lab-evidence workflows. The plugin uses the existing `reflexcore` connection, so Studio and Codex share the same queue and project settings.

~~~powershell
codex plugin marketplace add (Get-Location).Path
codex plugin add reflexcore@reflexcore-local
~~~

Open a new Codex session after installation so the new tools and workflows can be discovered.

## Offline lab evidence

Run the owned GoldSrc match harness with `-PublishMcpSummary` to make its redacted result queryable through `list_lab_runs`. It returns up to 20 recent summaries. The same run ID identifies the private harness results. The controller supplies contacts, requests, discharges and hits. A fresh server log independently confirms closed rounds, plants and winners. Cancellation, truncation and infrastructure failures leave the round verdict unknown. The reader validates the schema and file identity and projects only allowed fields. It exposes no screenshots, positions, paths, raw logs or game actions.

## Test

```powershell
cargo build --release --locked
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tasks\Test-Handoff.ps1 -Mcp
```

The fixture covers stdio initialization, tool discovery, the off switch, scope rejection, saved presets, approval, edited-checklist rejection, independent report readback, typed receipts, cancellation before execution and rejection of foreign lab summaries.

For the owned combat fixture, use list_combat_runs for discovery, get_combat_run for a diagnosis by run ID, and compare_combat_runs for compatible pairs. The returned evidence separates command delivery, primary attack, discharge, and damage. See [the fixture and reproduction commands](CS16-BENCHMARK.md#offline-combat-fixture).

The compositions array in list_skills describes the two CLI plans, typed ports, permissions and dependencies. Submission is direct_cli. This discovery result contains no artifact references or execution grant.

## Phase C approved composition checkpoint

Use submit_composition for a supported editor and output paths relative to a configured project. Studio approval is required before launch. Poll get_task_result with the returned task ID or call cancel_task. The client cannot approve its own request.

Developer checkpoints and the optional build provenance check are documented in [Codex integration](CODEX-INTEGRATION.md).

In a Git development checkout, build with tools/Measure-DevBuild.ps1 -Action Build before calling list_skills. The optional -DeveloperTools launcher switch adds get_validation_evidence to the same server; the Studio enable switch applies to both.
