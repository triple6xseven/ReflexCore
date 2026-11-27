# Codex Intelligence Bridge v0.3 development checkpoint

## Use on Windows

From the selected worktree root, run the following commands with a session identifier unique to the task. Use `bridge` or `mcp` as the component.

```powershell
.\tools\Measure-DevBuild.ps1 -Action Build
.\target\release\reflexcore.exe dev-context record session-1 bridge mutation-started
.\target\release\reflexcore.exe dev-context status session-1 bridge
.\tools\Measure-DevBuild.ps1 -Action Check
```

The checkpoint survives an interrupted process. A changed revision means inspect the selected component again. A matching revision means only that the observed inputs match. Every recorded operation has an unknown effect until an independent verifier supplies evidence. Checkpoints convey no authority. The operator's task and the current instructions still govern continuation.

## Scope, performance and privacy

Each observation samples HEAD, branch, scoped index entries, bytes of the explicit component inputs, root AGENTS.md, Cargo metadata and the roadmap twice. It rejects disagreement and redirected inputs. These are scoped fingerprints, not repository-wide snapshots. Unknown dependencies, nested instructions, changes reverted between samples, and arbitrary files outside the listed scope need separate inspection. SQLite transactions keep at most 256 session/component rows in the worktree-specific Git directory. Scope, event enums, revision hashes and hashed identifiers are stored. File contents, commands and conversation history are excluded. Missing files and absent checkpoints are distinct states. A corrupt database yields an error. Dormant mode has no worker, hook, model request or polling.

Release provenance is opt-in via the build wrapper. It records the default local locked release binary, compiler identity, worktree, HEAD and a fingerprint of the enumerated Cargo and Rust inputs before and after the build. It does not attest the OS, external toolchain installation, transitive native build inputs or already running processes. Existing MCP calls do not yet enforce this evidence. One local status sample measured 424 ms and 252 UTF-8 payload bytes before the newline. No subscription or productivity estimate follows from this sample.

## Installed capability matrix

- CLI 0.171.0-alpha.13.2 on Windows reported stable hooks and plugins enabled. Project hook invocation still requires operator trust. The fixture used real PowerShell and native checkpoint code with a synthetic lifecycle payload. Automatic invocation by the desktop client is unqualified.
- Generated App Server schemas contain thread/resume, excludeTurns, account/rateLimits/read, thread/tokenUsage/updated, usageLimitExceeded and turn/plan/updated. The CLI exposes stdio, daemon and proxy commands. No owned session or live desktop subscription was opened. Usage, reset and forecasts remain unavailable.
- The SDK can initiate separate programmatic sessions. This checkpoint uses no SDK, model turn, credentials or global registration. Existing plugin release and lab skills remain available through their previous installation.

Official references: [App Server](https://developers.openai.com/codex/app-server), [hooks](https://developers.openai.com/codex/hooks), [SDK](https://developers.openai.com/codex/sdk), [plugins](https://developers.openai.com/plugins/build/plugins), [Codex source](https://github.com/openai/codex).

## Project-scoped hook setup

After inspecting the source and building the native executable, configure command hooks in this project's .codex/hooks.json. Start with PostToolUse and the narrow matcher below. Replace both absolute paths with the reviewed worktree paths. Add a corresponding PreToolUse entry for in-flight capture. PreCompact can use the same command without a tool matcher. Keep a single registration. Review hooks in Codex before enabling. Remove only those entries to disable or uninstall. No setup runs automatically.

```json
{"hooks":{"PostToolUse":[{"matcher":"^(apply_patch|Edit|Write)$","hooks":[{"type":"command","command":"powershell.exe -NoProfile -File \"C:/project/tools/Record-DevHook.ps1\" -Worktree \"C:/project\"","timeout":5}]}]}}
```

The hook observes only events delivered for the selected worktree root and session. It discards oversized input, ignores shell operations, has no stdout on success and never stores the hook payload. A missing post-event leaves the previous in-flight observation intact. An ended tool is not a verified mutation. Reading status remains available manually without hooks.

## Continuation

First qualify actual desktop hook delivery, interruptions and compaction in a disposable trusted project. Bind build verification into the existing MCP registry read, with compact stale/unknown results and tests using different dirty worktrees. Then extend recovery to explicit objectives, verified build/test evidence, nested instruction dependencies and bounded history; qualify a managed App Server connection before adding usage UI. DI-1 and DI-2 are partial. DI-3 through DI-5 and the A/B/C productivity evaluation remain open. The cognitive-runtime roadmap is independent.
