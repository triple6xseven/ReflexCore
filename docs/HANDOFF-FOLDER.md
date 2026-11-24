# Verify a Handoff Folder

In Studio, open **Agent → Verify a Handoff Folder**. Select a local folder, choose an existing checklist or type a new checklist filename, and select a new report filename. When creating a checklist, enter one relative path per line. Append `| SHA-256` for files whose contents must match a digest. The checklist name defaults to its filename and can be edited in its JSON. The queue shows the task outcome. Open the chosen JSON report for the folder verdict and individual findings.

From PowerShell, run the same task directly with a [named checklist](../examples/handoff-checklist.json).

```powershell
cargo build --release --locked
$folder = (Get-Location).Path
$report = Join-Path $env:TEMP ("handoff-" + [guid]::NewGuid() + ".json")
.\target\release\reflexcore.exe handoff $folder "$folder\examples\handoff-checklist.json" $report
Get-Content -LiteralPath $report -Encoding UTF8
```

The report includes the run ID, checklist, and ordered findings. `Ready` requires all required files to be present and all requested checksums to match. Confirmed missing files and checksum mismatches yield `Needs attention` with a verified receipt. An unreadable or changed file yields `Needs attention` with an unverified receipt. CLI exit code 0 means a verified report was published. Use Ctrl+C to cancel the CLI, or the existing stop controls for a queued task.

The worker bounds checklist size to 512 KiB and 1,024 entries and streams checksums with a 64 KiB buffer. It uses local drive paths. Reparse points, device names, alternate streams, traversal, and network paths are rejected. The worker checks the opened file's resolved path before reading content. Findings describe the time each file was observed. A report is a series of observations, and the folder can change after an individual check. Hard links are treated as directory entries in the selected scope.

The worker creates a staging file beside the report, flushes it, and parses it from a new handle to compare the schema, run ID, checklist, observations, and verdict. It checks cancellation before a no-replace rename and independently reopens the published report before issuing a verified receipt. If cancellation arrives after publication, the report can remain and the receipt records an unknown effect. Temporary request inputs live in the private queue sidecar until terminal handling. Paths and checksums appear in the user-selected report. The shared receipt carries only IDs, outcome codes, and measurements.

## Design decisions

- Use native filesystem observations for an effect that Windows exposes directly. This follows the programmatic channel in [Microsoft Hybrid Computer Use](https://github.com/microsoft/Hybrid-Computer-Use/blob/main/instructions/hybrid-code.md).
- Require an independent read of the saved artifact and withhold verification when the expected artifact cannot be established. This follows the separate saved-state check in [OpenAdapt Flow](https://github.com/OpenAdaptAI/OpenAdapt/blob/main/packages/flow/README.md).
- Give the test harness its own initial fixtures and independent evaluator for the report and queue receipt. This follows the task design in [Windows Agent Arena](https://github.com/microsoft/WindowsAgentArena/blob/main/docs/Develop-Tasks.md).

## Reproduce

Run from the repository root using Windows PowerShell 5.1.

```powershell
cargo test --locked
cargo build --release --locked
.\tasks\Test-Queue.ps1
.\tools\ReflexCore-ControlCenter.ps1 -UiSmoke
.\tasks\Test-Handoff.ps1 -Benchmark -Sessions 4 -WarmRuns 5
# With the Ollama server stopped
.\tasks\Test-Handoff.ps1 -RequireOllamaStopped
```

## Build a draft from text

When creating a checklist in Studio, enter a description and select **Build checklist from text**. Review the proposed entries in the editor before saving, then choose a report destination to run the check. Existing lists can still be reused directly.

The local parser handles short English and Russian requests with explicit filenames. Quote names with spaces and extensionless filenames. Attach each digest to its file using syntax such as `Check release.zip SHA-256: <64 hexadecimal digits> and README.md.` Requests like "check the latest archive" require a filename. The parser leaves the editor untouched when it needs clarification or rejects a path. The native worker still enforces its filesystem boundary during execution.

Run `powershell.exe -NoProfile -File tasks/Test-HandoffDraft.ps1` to evaluate extraction, clarification and scope validation. The optional draft runs without a model or a network call.
