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

Release provenance is opt-in via the build wrapper. It records the default local locked release binary, compiler identity, worktree, HEAD and a fingerprint of the enumerated Cargo and Rust inputs before and after the build. It does not attest the OS, external toolchain installation, transitive native build inputs or already running processes. In a development checkout list_skills requires matching build provenance and holds the executable open against replacement through registry execution. Missing or stale evidence returns a compact rebuild instruction. Source-free installations retain their previous catalog semantics. Start the existing MCP launcher with -DeveloperTools to expose the optional read-only get_validation_evidence tool. No additional server registration is needed. One local status sample measured 424 ms and 252 UTF-8 payload bytes before the newline. No subscription or productivity estimate follows from this sample.

## Installed capability matrix

- CLI 0.171.0-alpha.13.2 on Windows reported stable hooks and plugins enabled. Project hook invocation still requires operator trust. The fixture used real PowerShell and native checkpoint code with a synthetic lifecycle payload. Automatic invocation by the desktop client is unqualified.
- Generated App Server schemas contain thread/resume, excludeTurns, account/rateLimits/read, thread/tokenUsage/updated, usageLimitExceeded and turn/plan/updated. The CLI exposes stdio, daemon and proxy commands. The explicit tools/Read-DevUsage.ps1 probe opened an owned stdio connection, initialized, read official account limit windows, and closed. The local acceptance returned two windows with durations and reset timestamps. No model thread or turn was created. Desktop event visibility, continuous notifications and forecasts remain unqualified.
- The SDK can initiate separate programmatic sessions. This checkpoint uses no SDK, model turn, credentials or global registration. Existing plugin release and lab skills remain available through their previous installation.

Official references: [App Server](https://developers.openai.com/codex/app-server), [hooks](https://developers.openai.com/codex/hooks), [SDK](https://developers.openai.com/codex/sdk), [plugins](https://developers.openai.com/plugins/build/plugins), [Codex source](https://github.com/openai/codex).

## Recovery and project hook setup

Start from the worktree root. Inspect the proposed configuration, then explicitly install the project hooks and pinned observer. Existing custom hooks are preserved; inspect and merge them manually. Remove only this installation with the Remove action. Review the project's hook commands in Codex before use. Hooks are disabled until trusted where the client requires trust.

```powershell
.\tools\Set-DevHooks.ps1 -Action Inspect
.\tools\Set-DevHooks.ps1 -Action Install
.\tools\Invoke-DevObserver.ps1 -ObserverArgs @('declare',$env:CODEX_THREAD_ID,'bridge','Qualify interrupted development','Inspect the edited entry point')
.\tools\Invoke-DevObserver.ps1 -ObserverArgs @('resume',$env:CODEX_THREAD_ID,'bridge')
.\tools\Set-DevHooks.ps1 -Action Remove
```

Use the actual session ID delivered by hooks. When the CLI environment does not provide it, supply the known session identifier explicitly. Declare only non-sensitive objectives and next steps. The observer records intentions verbatim within a byte limit. Raw hook commands and tool results are discarded. Returning from a tool only records a return. Recent events and unresolved operation classes are observations with unknown effects. When a tool_use_id is delivered, the observer hashes it and correlates returns to starts. Overlapping operations without IDs remain class-level observations. The history retains up to 1024 events across a worktree. Migration preserves previous checkpoints; old declarations without a path baseline return an unknown change list.

The separate native observer is built from the shared context module, probed for protocol v2 and pinned by SHA-256 in the worktree Git directory. The local pointer is replaced atomically. It runs even if target/release/reflexcore.exe is removed during a build. Local file ownership is the trust boundary. This does not protect against a malicious process with the same user's privileges. Refresh the observer explicitly after editing its source. Removing hooks leaves private history available.

Enable DeveloperTools on the existing MCP launcher to discover get_development_context, get_checkpoint, get_validation_evidence and get_usage_status. The first two return a scoped, bounded packet. get_development_context additionally checks current release provenance. The default component is bridge; request mcp for MCP-specific tasks. Automatic selection requires exactly one declared session in that component. Evidence without a matching independent verifier is unknown. Declare a new next step when the objective changes. Source freshness covers listed inputs and their ancestor AGENTS.md files. A change outside the known dependency boundary needs independent inspection.

## Acceptance and continuation

- DI-1: worktree and session isolation, schema migration, bounded declaration and observations, per-input changes, independent release provenance. The worktree recovery fixture has a run-specific receipt bound to the exact local build stamp and verifier script. Other test suites do not yet publish receipts.
- DI-2: a project-scoped install/inspect/remove mechanism and a stable observer. PowerShell handler and missing-final-event behavior have been exercised with fixture payloads. Actual Desktop delivery, compaction and interruption require an interactive trusted project. A subscriber limit was never deliberately exhausted.
- DI-3: explicit managed account limit reads; desktop turn events, persisted observations, token usage, managed resume and forecast remain open.
- DI-4: four opt-in developer tools and three source plugin skills. The primary profile still has 0.2.0. The installed Codex CLI added the local marketplace and installed 0.3.0 with all five skills into an isolated profile. Runtime selection of the upgraded skills has not been verified. No duplicate MCP registration is required.
- DI-5: no Studio monitor yet. No measured subscription savings or general A/B productivity result.

The deterministic acceptance script tasks/Test-DevResume.ps1 uses a real MCP process and an isolated Git repository with no main executable. It declares a task, changes source, observes a test start, omits its completion, and retrieves the declared next step from a fresh client. Two warm-host / cold-server observations took 1595 and 1627 ms; packet sizes differed across revisions. These figures include PowerShell startup and C# compilation. After adding current release provenance, a cold MCP call took 1580 ms and the packet was 894 bytes, with zero model requests by the bridge. The fixture also covers disabled MCP, a foreign observer pointer and ambiguous sessions.

**Next:** open a disposable trusted worktree in Desktop, review its project hooks and verify delivered mutation, shell, Stop, Interrupt and compaction events against the observer history. Then qualify real tool-call IDs. The packet already includes the dedicated worktree recovery fixture verdict. Until then, treat missing end events as unknown. The independent cognitive-runtime roadmap remains authoritative.


Run "tools/Measure-DevBuild.ps1 -Action VerifyRecovery" after an explicit release build to execute the two-worktree fixture. Both developer evidence and recovery tools expose worktree_recovery_test. It is verified only for a matching build and verifier. Missing, malformed or interrupted evidence is unknown. Changes to the source or verifier invalidate the receipt. Reading evidence never starts the fixture.

## Desktop hook delivery qualification

The live thread reported a different cwd from the linked acceptance checkout. Inspection of the default profile found an exact trusted-project entry for the Desktop project and none for the acceptance directory or the main checkout. Only the acceptance directory had project hooks. A separate managed server returned empty hook lists for both requested cwds; its thread-specific hook query could not access the loaded Desktop thread. On this installation the local daemon proxy was unavailable. There were zero observed lifecycle events after one edit and one shell command. Missing delivery, trust refusal and matcher omission cannot be distinguished by the absence of a handler log alone.

After installing the current observer, inspect the disposable configuration using Set-DevHooks.ps1 -Action Inspect -Diagnostic. In a fresh disposable project, -Action Install -Diagnostic creates the configuration. Preserve any existing configuration before an explicit replacement. Open the acceptance folder as its own Desktop project and review the exact commands in Settings > Hooks. A changed executable path, command or script may require another approval. Inspect or remove using the same mode. No global trust edit is needed. A plugin-bundled hook also requires operator review. A managed App Server can observe its own client connection; neither approach supplies retrospective evidence for the Desktop turn.

The interrupt command directly invokes the installed hash-named native observer through cmd.exe. It performs no Git operation, source fingerprint, model call, PowerShell startup or runtime build. It records a bounded session-keyed arrival in the private worktree SQLite journal. Explicit recovery reads the latest twelve arrivals for the requested session. An arrival cannot establish a completed operation. Diagnostic mode routes all five lifecycle handlers through this path and retains at most 128 sanitized diagnostic rows. Handler duration ends after the event transaction and before storing telemetry. If startup or storage fails, the process exits nonzero; inspect the client hook result. Match and trust decisions occur in the client before invocation.

For local inspection, query the diagnostic table of reflex-hook-arrivals.sqlite under the worktree-specific Git directory. Its columns are event, at_ms, tool, has_session, matched, reason and elapsed_us. The readiness check uses hook-protocol and writes no event. Seven local command-launch probes measured median 34.0 ms and maximum 66.1 ms. These measurements exclude payload handling and disk writes. Live interrupt latency and Desktop delivery remain unverified. See the [official hook lookup and trust rules](https://developers.openai.com/codex/hooks).
