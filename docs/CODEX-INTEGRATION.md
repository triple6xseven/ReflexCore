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

## Earlier Windows fixture measurements

The deterministic acceptance script tasks/Test-DevResume.ps1 uses a real MCP process and an isolated Git repository with no main executable. It declares a task, changes source, observes a test start, omits its completion, and retrieves the declared next step from a fresh client. Two warm-host / cold-server observations took 1595 and 1627 ms; packet sizes differed across revisions. These figures include PowerShell startup and C# compilation. After adding current release provenance, a cold MCP call took 1580 ms and the packet was 894 bytes, with zero model requests by the bridge. The fixture also covers disabled MCP, a foreign observer pointer and ambiguous sessions.

Run "tools/Measure-DevBuild.ps1 -Action VerifyRecovery" after an explicit release build to execute the two-worktree fixture. Both developer evidence and recovery tools expose worktree_recovery_test. It is verified only for a matching build and verifier. Missing, malformed or interrupted evidence is unknown. Changes to the source or verifier invalidate the receipt. Reading evidence never starts the fixture.

## Desktop hook delivery qualification

The live thread reported a different cwd from the linked acceptance checkout. Inspection of the default profile found an exact trusted-project entry for the Desktop project and none for the acceptance directory or the main checkout. Only the acceptance directory had project hooks. A separate managed server returned empty hook lists for both requested cwds; its thread-specific hook query could not access the loaded Desktop thread. On this installation the local daemon proxy was unavailable. There were zero observed lifecycle events after one edit and one shell command. Missing delivery, trust refusal and matcher omission cannot be distinguished by the absence of a handler log alone.

After installing the current observer, inspect the disposable configuration using Set-DevHooks.ps1 -Action Inspect -Diagnostic. In a fresh disposable project, -Action Install -Diagnostic creates the configuration. Preserve any existing configuration before an explicit replacement. Open the acceptance folder as its own Desktop project and review the exact commands in Settings > Hooks. A changed executable path, command or script may require another approval. Inspect or remove using the same mode. No global trust edit is needed. A plugin-bundled hook also requires operator review. A managed App Server can observe its own client connection; neither approach supplies retrospective evidence for the Desktop turn.

The interrupt command directly invokes the installed hash-named native observer through cmd.exe. It performs no Git operation, source fingerprint, model call, PowerShell startup or runtime build. It records a bounded session-keyed arrival in the private worktree SQLite journal. Explicit recovery reads the latest twelve arrivals for the requested session. An arrival cannot establish a completed operation. Diagnostic mode routes all five lifecycle handlers through this path and retains at most 128 sanitized diagnostic rows. Handler duration ends after the event transaction and before storing telemetry. If startup or storage fails, the process exits nonzero; inspect the client hook result. Match and trust decisions occur in the client before invocation.

For local inspection, query the diagnostic table of reflex-hook-arrivals.sqlite under the worktree-specific Git directory. Its columns are event, at_ms, tool, has_session, matched, reason and elapsed_us. The readiness check uses hook-protocol and writes no event. Seven local command-launch probes measured median 34.0 ms and maximum 66.1 ms. These measurements exclude payload handling and disk writes. Live interrupt latency and Desktop delivery remain unverified. See the [official hook lookup and trust rules](https://developers.openai.com/codex/hooks).

## Managed App Server and pending CI

Run tools/Read-DevUsage.ps1 -Action Qualify to start an explicit managed stdio connection, read official account windows, create and read one ephemeral thread, and correlate thread/started. This uses no model turns. Observed rate-limit update notifications are counted during the short request sequence. The latest successful window snapshot is saved under the worktree-specific Git directory. Reset times are official timestamps. Exhaustion forecasts remain unavailable. The probe stops with its connection and cannot observe unrelated Desktop activity. Resume requires an explicit thread ID in the same worktree, asks for no turns, and issues no model prompt.

Before ending work that triggered CI, use the installed observer with pending-ci, session ID, component, commit SHA, and GitHub run ID. Use unknown until a run ID is available. Recovery returns the last recorded CI operation for this session and component with an unknown outcome. Inspect the exact run when resuming. This avoids waiting in the current Codex turn. Observer installations must be refreshed from this revision before using the new checkpoint schema.

## Installed integration and adaptive responses

Plugin 0.3.1 is installed with all five skills. A subsequent Codex session exposed reflex-continue, reflex-resume, and reflex-validate as available skills. This development task loaded reflex-continue. Automatic selection in the Desktop interface is unverified.

The existing reflexcore registration can use -RuntimeRoot to keep the deployed queue, enable flag, project mappings and approvals in the runtime installation. The launcher worktree owns the developer observer, source fingerprint and build provenance. Before migration, save the current Codex configuration. Roll back by restoring the previous reflexcore entry from that backup. Keep only one registration and opt into developer tools with -DeveloperTools.

A fresh managed Codex App Server used the migrated registration through mcpServer/tool/call. The recovery packet identified the declared next step and the edit to docs/MCP.md. The previous context revision returned an unchanged acknowledgement after source and build evidence were reconciled. A changed revision returns the current recovery packet. Use a known revision only with context held by the current task. Clear it after a thread change, compaction or uncertain delivery.

Usage reads default to the local snapshot and report age. The two-minute threshold describes snapshot recency. Account identity remains unverified for cached observations. Pass refresh=yes to query the currently signed-in account explicitly. Cached reads avoid starting a Codex App Server and the integration has no polling loop.

The installed connection measured 2623 ms and 1064 serialized packet bytes for a cold recovery. A warm unchanged reply took 925 ms and returned 107 bytes. A warm cache read took 144 ms. These are individual measurements with zero additional model turns. Component CPU costs, private memory and token savings remain unmeasured.

## Current DI status

- DI-1 has worktree-scoped checkpoints, release provenance, verified fixture evidence and pending CI identity. GitHub Actions run 46072684420 completed successfully on attempt 1 for d2c14202a3d20f950429d6e0c6447555d7bf4f04. Run 46073391351 for 1a1989db120f9975b1585336321b10bb56516d4b was in progress on attempt 1 at the continuation check. The worktree-local CI observation file retains both results. MCP joins those observations only on the exact commit and run ID. Retrieval performs no network polling.
- DI-2 has optional native Desktop diagnostics. Live event delivery remains unverified.
- DI-3 has official usage lookup and a bounded managed turn probe. The authorized single ephemeral turn delivered thread/started, turn/started, thread/tokenUsage/updated, account/rateLimits/updated and turn/completed. The probe recorded a completed turn and 22261 total tokens as reported by the server. No plan update or interruption was delivered in that turn. Classification tests cover temporary rate limiting, context exhaustion, and authoritative usage-limit exhaustion. The reducer retains a confirmed exhaustion classification when a subsequent generic failure arrives. Private turn receipts are written after each accepted lifecycle event, without a model-generated summary.
- DI-4 includes installed plugin 0.3.1, single MCP registration, cached usage and bounded deltas. The source plugin 0.3.2 extends checkpoint guidance. A full packet is returned when the previous revision is unavailable, the selected worktree or session changes, or the delta would be larger. The installed registration returned 107 bytes in 917 ms for an unchanged packet and 335 bytes in 949 ms for a changed declaration. These are single warm examples. CPU, peak memory and phase attribution remain open.
- DI-5 Studio monitoring remains open.

Run tools/Read-DevUsage.ps1 -Action QualifyTurn only for an explicit live qualification. It sends one fixed prompt in an ephemeral managed thread. Normal usage refresh, cached reads, and recovery send no model requests. The listener is bounded to the owned connection and prompts no second turn.

A split runtime root continues to serve the installed project mappings and handoff queue. The catalog and text composition require compatible runtime evidence and queue contracts. The split launcher now rejects those calls instead of using developer evidence for the installed runtime. Keep the registry independent until runtime provenance can be verified against its own build.

Next, automate one-shot CI observation refresh and profile native and PowerShell phases before optimizing the warm path. Qualify interruption, plan updates and installed runtime compatibility separately from the one-turn smoke.
