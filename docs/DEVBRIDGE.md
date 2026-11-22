# ReflexCore Dev Bridge 0.2.0

A local, user-approved, transactional code-update protocol. It extends the 0.1.1 tray bridge. It has no network listener, no remote execution endpoint, and does not give the ChatGPT conversation direct access to the PC.

## Workflow

From a Windows PowerShell 5.1 window in the ReflexCore project:

```powershell
& .\tools\ReflexDev.ps1 -Action inventory
& .\tools\ReflexDev.ps1 -Action preview -Manifest .\examples\devbridge_sample.json
& .\tools\ReflexDev.ps1 -Action apply -Manifest .\examples\devbridge_sample.json
& .\tools\ReflexDev.ps1 -Action status
```

`apply` is an **explicit approval** to enqueue a manifest with the existing tray bridge. Tray shows `Running` and `Completed`/`Failed`; Ctrl+Alt+P stops its supervised process tree.

### Patch manifest schema

```json
{
  "schema": "reflexcore.devpatch.v1",
  "name": "add-observer-test",
  "writes": [
    { "path": "examples/new_feature.rs", "content": "fn main() {}\n", "expected_sha256": null }
  ]
}
```

For existing files, `expected_sha256` **must** be the current SHA-256 from `inventory`. For new files it must be null. Only source paths within `src/`, `tests/`, `examples/`, `tools/`, `tasks/`, `Cargo.toml`, and `AGENTS.md` are accepted. The self-updater files are protected from modification through this protocol. The manifest does not contain shell commands; it only contains source contents.

The patch worker backs up previous content, validates file hashes, writes an in-flight recovery journal, applies changes, runs `cargo test --all-targets` and `cargo build --release`. Successful results are committed; failures roll back changed source files.

**Forced stop caveat:** Ctrl+Alt+P terminates the worker immediately, so rollback occurs on the next worker run or on manual `-Action recover`, not during the forced stop. Do not launch any new tools against source until recovery completes.

### Privacy

Patch manifests, rollback journals, local status and build logs live in ignored `data/dev/`; backups live in ignored `backups/`. Status JSON contains no source text or field values. Build diagnostics are retained locally in `data/dev/logs`, and may contain sensitive content. Review them before sharing. Do not commit local manifests or logs.

### Troubleshooting

```powershell
& .\tools\ReflexDev.ps1 -Action selftest
& .\tools\ReflexDev.ps1 -Action recover
& .\tools\ReflexDev.ps1 -Action diagnostics
```

`diagnostics` prints recent local Cargo errors and may contain sensitive strings. `inventory` lists code filenames, byte sizes and SHA-256 only; it does not print source contents.

This is a development helper, not a substitute for Git version control. Use Git commits as durable milestones after reviewing changes.