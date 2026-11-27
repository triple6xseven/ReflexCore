# Universal Skill Runtime 0.8.3

## Working checkpoint

The first A/B delivery transfers one executable method between two editors.
`artifact.verify_saved_text@1` independently reopens the file produced by this
run and checks ordinal text equality. The checker emits a typed receipt only
after reading the complete bounded file. No model is involved. The operator's
choice of editor determines which application actually performs the save.

Use **Agent → Skill library** to inspect the chosen binding, required capabilities,
foreground requirement and verified receipts retained locally. Selecting a
completed editor job in the queue shows its skill and adapter. MCP clients can
read the same catalog with `list_skills` and a retained result with
`get_task_result(task_id)`. An editor receipt grants no new execution permission.

## Registry, execution and compatibility

* L0 contains the local directory-pinning and bounded readback primitives.
  Handoff and saved-text verification use the same safe file opener.
* L1 is the existing Rust registry, now including the executable verifier. A
  request names the skill, version, adapter and execution mode. The binder
  requires the exact operation, compatible contract version and every semantic
  capability. A missing capability or an incompatible requested mode stops binding.
* L2/L3 contain the two application supervisors. The WinForms adapter drives UIA
  against its owned HWND/PID and creates a fresh output exclusively. Background
  mode supports both disposable workers and an opt-in native session. Notepad
  reserves a new file, opens its own identifiable document, checks foreground
  ownership and editor contents, edits, then saves. Its explicit input permission
  remains mandatory. The deterministic route uses zero inference calls.
* L4 already has a two-edge Goal in the WinForms demo. Each transition checks
  its precondition and effect. This is the first consumer for a future typed
  composition change. The existing Dijkstra planner and Flow executor remain
  the owners of planning and UI dispatch.

The reusable method operates on the run-owned file, expected text and the
binding's encoding policy. WinForms supplies exact UTF-8. Notepad also permits
UTF-8/16/32 with recognized byte-order marks. Line endings and Unicode are
compared exactly. Paths, selectors, focus, edit methods, exclusive creation and
save commands remain adapter responsibilities. The bound checker reads at most
4,097 bytes to enforce a 4,096-byte artifact limit. Local paths are pinned through
their directory chain. Reparse points and network targets are unsupported.

The Notepad supervisor first checks the executable binding, before creating the
file. A separate bounded verifier may reopen the output during a nine-second
settling window. Only reads are retried. The supervisor observes stop signals
while waiting and can terminate its own helper. The existing session supervisor
handles UIA worker timeouts and crashes. A failed comparison, an unavailable
readback and a cancelled action are separate Rust outcomes. Notepad's outer
PowerShell task still coalesces some verifier errors into a generic task failure.

## Receipts, retained experience and other components

`reflexcore.skill.evidence.v1` carries the run ID, skill ID/version, adapter
ID/version, verifier version, outcome and elapsed readback microseconds.
The queue validates the embedded identity and version against its terminal
receipt before retention. Legacy receipts remain readable. MCP access uses
the existing enable switch and exposes the typed, allowlisted result.
The evidence has no file contents, paths, digests, window titles or model output.
The Skill Library's retained count is a local history count with a 100-job
retention bound. It is unsuitable as a lifetime reliability estimate.

`motion.probe`, `motion.fixed`, `motion.calibrated` and `cs16.advance` keep their
existing lab executors and appear as experimental. Goal/Flow manifests still
describe transitions for their existing callers. Handoff and extension renaming
remain queue workflows. Vision is an observer. Citadel and GoldSrc retain their
owned environment adapters. The neural runtime remains an experimental policy
catalog. These entries do not inherit editor permissions or evidence.

Keep existing SQLite route reliability, Notepad's per-editor method cache, and
experimental learning/replay data separate. Notepad updates its existing cache
only after successful readback. No new automatic training or cross-domain
statistics are introduced. For phase E, key proposed experience by skill,
adapter, capability and verifier versions, environment compatibility, provenance
and classified outcome. Validate migration before aggregating old evidence.

## Reproduction on Windows

From the feature worktree, build once. Binding inspection is read-only.

```powershell
cargo build --locked --release
.\target\release\reflexcore.exe learning registry
.\target\release\reflexcore.exe learning bind artifact.verify_saved_text 1 notepad foreground
.\target\release\reflexcore.exe learning bind artifact.verify_saved_text 1 notepad background
```

The last command must fail. The next group uses an unlocked interactive desktop
and synthetic files. The Notepad test independently checks an ordinary file and
a Unicode variation. Run each desktop test separately so foreground checks are
meaningful.

```powershell
$env:REFLEXCORE_UIA_WORKER='session'
.\target\release\reflexcore.exe agent verified-demo --execute --background
.\tasks\Test-NotepadSkill.ps1 -Runs 2 -AllowInput
.\tasks\Test-Queue.ps1 -UiaFixture
.\tools\Test-NativeSession.ps1 -AllowVisibleUI
.\tasks\Test-Handoff.ps1 -Mcp
.\tools\ReflexCore-ControlCenter.ps1 -SelfTest
.\tools\ReflexCore-ControlCenter.ps1 -UiSmoke
```

Unit and protocol checks run unattended. See [measurements](BENCHMARKS.md)
for the comparison method, sample sizes and limitations.

Run `tasks/Test-Queue.ps1` to exercise the editor decision without input.
Add `-AllowInput` on an unlocked desktop to compare both queued Unicode files
to their expected text after the history entries are published.

## Research decisions

The following sources informed the design. No upstream code, packages, weights or
benchmark datasets were imported. Licensing notes refer to the referenced work.

| Source | Decision used in this milestone |
| --- | --- |
| [Microsoft UFO](https://github.com/microsoft/UFO) · MIT | Keep application-specific UI ownership in the adapter. Bind the requested application explicitly. |
| [Windows Agent Arena task evaluators](https://github.com/microsoft/WindowsAgentArena/blob/main/docs/Develop-Tasks.md) · MIT | Check resulting application state from an independent evaluator. Reopen the actual file in acceptance. |
| [Voyager skill library](https://github.com/MineDojo/Voyager) · MIT | Give reusable methods stable catalog entries. Admission of newly discovered code remains a later, explicit step. |
| [OpenAdapt Flow](https://github.com/OpenAdaptAI/OpenAdapt/tree/main/packages/flow) · MIT | Qualify a concrete operation separately from replay. A dispatched save needs disk evidence. |
| [BehaviorTree.CPP](https://github.com/BehaviorTree/BehaviorTree.CPP) · MIT | Keep the observable precondition, bounded action and terminal result separate so composition can stop at an unfulfilled edge. |
| [ROS 2 Actions, upstream documentation](https://github.com/ros2/ros2_documentation/blob/rolling/source/ROS-Framework/interfaces/About-Actions.rst) · CC BY 4.0 documentation | Keep cancellation and terminal results tied to the same goal identity. The documentation source is available at its relocated path. |
| [Gymnasium](https://github.com/Farama-Foundation/Gymnasium) · MIT | Keep infrastructure truncation or missing evidence outside the verified-success count. |
| [MCP specification and license](https://github.com/modelcontextprotocol/modelcontextprotocol) · MIT/Apache-2.0 transition by contribution | Use structured discovery and versioned results. Retain Studio approval at the execution boundary. |
| [Sutton, Precup and Singh, 1999](https://ics.uci.edu/~dechter/courses/ics-295/winter-2018/papers/Sutton-Precup-Singh-AIJ99.pdf) · published research, copyright Elsevier | Model eligibility and termination explicitly. The transferred method is deterministic. |

Win32, UIA, known-folder discovery, file handles, Job Objects and local IPC cover
the demonstrated task. A future read-only platform adapter can expose ETW resource
observations or Windows Graphics Capture/DXGI frames through scoped user-mode
capabilities. A driver would require a measured user-mode limitation, documented
WDK interface, threat model, signing, recovery and independent review.

## Continuation

### First composition boundary

The editor workflows now share the transition from verified saved text to a
verified queue result. Before launching a worker, the supervisor creates a fresh
attempt ID and retains the expected editor locally. The worker receives the ID
in its private process environment. WinForms uses it for the existing UIA
exchange, artifact and evidence. Notepad uses it for its document token and
readback. Direct CLI runs still generate their own IDs.

To commit success, the supervisor requires the original task and attempt,
the expected editor, skill/adapter/verifier v1, a valid readback measurement,
a verified effect and successful worker exit. A self-consistent receipt from a
different attempt cannot complete this transition. Incompatible or absent
evidence after exit zero is retained as unverified. A stop acknowledged before
commit wins even after the worker exits. The history then records cancellation
with an unknown effect if the save may already have happened. A per-task mutex
orders the two decisions. Tray retries a contended commit on its next tick.

The contract provides correlation between trusted local components. The attempt
ID is visible to the worker and provides no authentication against a compromised
worker. Historical receipt formats and independent CLI usage remain supported.
Restart recovery marks abandoned claims interrupted.

The public Actions API records a successful [Windows runtime build for the base
commit efa3436](https://github.com/triple6xseven/ReflexCore/actions/runs/45867783309).
The published [A/B checkpoint also passed Windows CI](https://github.com/triple6xseven/ReflexCore/actions/runs/45905594907).
The workflow triggers on push and pull request with read-only repository
contents permission. Administrative Actions settings returned HTTP 401 through
the unauthenticated API. This branch adds unattended binding checks. UI focus,
disk saves through actual editors, and in-flight fault probes need an interactive
desktop and were run separately.

**Next implementation task (C)**. Use the same typed proof as the input to a
second separately authorized skill in a bounded Goal. Recheck the artifact's
current state before that skill can mutate it. Test replacement of the file
between the two skills, stop propagation and fresh recovery. The current shared
transition ends at the queue result; general multi-skill scheduling is still open.

**D** will collect read-only discovery candidates from UIA or approved schemas.
Admission progresses from discovered to candidate, validated, approved and
executable, with an explicit deprecation state. **E** will qualify compatibility
and reliability on held-out environments. **F** will require bounded declarative
manifests, compatible versions, validated dependencies, trusted native adapters
and revocation. These phases remain open. See [the official roadmap](ROADMAP.md).
