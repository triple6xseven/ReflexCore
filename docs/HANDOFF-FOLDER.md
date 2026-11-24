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

In Studio, open **Agent**, type into **Describe a folder task**, and select **Preview request**. Choose your folder and a new checklist filename. You can also draft from text while creating a checklist. Review the proposed entries in the editor before saving, then choose a report destination to run the check. Existing lists can still be reused directly.

The local parser handles short English and Russian requests with explicit filenames. Quote names with spaces and extensionless filenames. Attach each digest to its file using syntax such as `Check release.zip SHA-256: <64 hexadecimal digits> and README.md.` Requests like "check the latest archive" require a filename. The parser leaves the editor untouched when it needs clarification or rejects a path. The native worker still enforces its filesystem boundary during execution.

Run `powershell.exe -NoProfile -File tasks/Test-HandoffDraft.ps1` to evaluate extraction, clarification and scope validation. The optional draft runs without a model or a network call.

## Change file extensions

In **Agent**, select **Change file extensions** or enter a supported request in the same text field and select **Preview request**. Try `Change extensions from .txt to .log` or `Поменяй расширения всех файлов на .log`. Pick a local folder. If using the button, enter the new extension and select **Preview**. Leave the old extension blank to include files with any extension and extensionless files.

Review the current and proposed names, select **Rename files**, and confirm. The action renames files in the selected folder and skips subfolders and links. Existing destinations block the preview or execution. If Windows blocks a rename after some files have moved, the dialog shows how many completed. The action changes filenames only; it does not convert the file format.

Select **Open rename logs** in the rename dialog to open `%LOCALAPPDATA%\ReflexCore\rename-history`. Each private JSON Lines file records the folder, UTC times, original and new filenames, and the final count. The app flushes an intent before each move and records completion immediately afterward. An intent without a completion calls for checking both filenames after an interruption. The app requires a writable journal before it starts. Moves use Windows no-overwrite semantics in the same folder. The worker stops at the first error and reports any files already renamed. This feature does not delete files or roll back successful moves automatically.

Run `powershell.exe -NoProfile -File tasks/Test-ExtensionRename.ps1` to exercise the parser and verify changes on synthetic files.

## Check, then rename

In **Agent**, enter one supported two-step request, such as `Check README.md, then change .txt to .log.` or `Проверь, что в папке есть README.md, затем поменяй .txt на .log.`. **Preview request** shows the two steps. Choose the folder and review the checklist. When the first job finishes, select it in the task queue. Its result card shows counts for found, missing, mismatched, unreadable and changed files. **Open report** is available when the selected run's local report matches its receipt. The report path stays in private task storage.

**Preview next step** is available after a verified **Ready** result. The preview uses the same folder. Confirm the displayed rename list to queue it. The worker checks that the approved preview still matches and checks the original checklist and folder again immediately before entering the rename operation. The readiness check is a point-in-time observation. Existing destinations remain protected.

Use **Stop task** or **Cancel selected** to stop the queue worker between moves. Studio shows the completed count. **Partial** indicates a run that stopped after some moves. After **Interrupted**, the result card shows the count durably recorded in the local journal when available. An interruption during a move can leave its outcome unknown. Inspect the folder before retrying.

Run `tasks/Test-Handoff.ps1` for both language forms, the result gate, an independent check of a queued rename, and pending cancellation. Run `tasks/Test-ExtensionRename.ps1` for cancellation after one file and partial-failure behavior.
