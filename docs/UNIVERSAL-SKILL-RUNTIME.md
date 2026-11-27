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

## C1 checkpoint: process-local verified source

Set `REFLEXCORE_CHECK_ARTIFACT_TRANSFER=1` to exercise the private transfer
on the final background or foreground WinForms readback, or on a Notepad
fixture save. Public receipts retain their existing schema. Each source
retains its directory chain and read-only file handle, denies shared write
and delete, and records the adapter, attempt, length and SHA-256 for at most
4096 bytes. Consumption takes ownership, checks the attempt and adapter and
reads that handle again. Only local NTFS regular files with one link and a
nonzero file index qualify. A returned byte snapshot can supply a derived
copy; it gives no write access to the original.

Windows defines the volume serial and file index in
[handle information](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfileinformationbyhandle).
The source holds the object open throughout its lifetime under the documented
[file sharing rules](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew).
An open writer can prevent acquisition. The snapshot boundary is process-local.
The public verifier cannot reconstruct a source or grant consumer permission.

Reproduce with `cargo test --locked saved_text`, a release build, the switch
above and `agent verified-demo --execute --background` or
`tasks/Test-NotepadSkill.ps1 -AllowInput -Runs 1`. The concurrent fixture
attempts a write and rename before allowing consumption to proceed. Timing
percentiles for composition remain outstanding.

Next checkpoint C2: preflight a bounded typed plan with a distinct consumer
permission before launching the editor. Then pass the private source within
the verifying process to a separately authorized derived-copy skill. C1
exercises read-only transfer; C2 through C5 remain open.

## C2/C3 checkpoint: compose a verified text copy

Run from the repository root after a locked release build. Choose an existing
local NTFS parent and a fresh output name. The five explicit grants apply to
this direct invocation only. Available producers are `notepad`, `winforms`
and `winforms-background`.

```powershell
$path = Join-Path $env:TEMP ('derived-' + [guid]::NewGuid() + '.txt')
.\target\release\reflexcore.exe agent compose-text winforms-background $path ' — reviewed' --create --verify --consume --derive --publish
.\tasks\Test-TextComposition.ps1 -AllowInput
```

The only admitted plan is editor.create_document → artifact.verify_saved_text
→ artifact.derive_text → artifact.verify_derived (all v1). Preflight checks
the complete ordered chain, grants, adapter capabilities, suffix budget and
destination before launching the editor. Rust passes the private live source
by value into the consumer. The consumer rechecks the pinned object, consumes
one snapshot, checks its encoding against the verified text and emits UTF-8
without a BOM, preserving scalar values and line endings. A new acquisition can
yield another snapshot. After consumption the source is free to change. If
replacement happened before acquisition, matching text cannot establish the
identity of the object the editor originally opened.

Derived bytes are staged in a newly created file in the pinned destination
directory. Independent reads check its identity and exact contents both before
and after no-replace rename by handle. The writer denies competing writes and
deletes until terminal readback. Dropping unpublished staging requests deletion
by handle. Process termination can strand a staging file. Cancellation after
publication can leave a complete copy. Both applications retain their original
fixture; synthetic files remain local for inspection. Receipts contain skill
versions, adapter and run identity. No receipt carries executable authority.

Current entry is CLI-only. Global stop and a deadline are checked at skill
boundaries; the WinForms producer retains its existing per-action deadlines.
Queue stop ordering has not been qualified for the new workflow. Next checkpoint:
add cooperative interruption probes at each dispatch and publication boundary,
worker-crash recovery, and a paired resource benchmark before Studio/MCP submission.

## Sequential reuse and cancellation checkpoint

Two built-in plans now share a bounded sequential interpreter. The longer plan
adds derive and verify nodes consuming the preceding verified UTF-8 snapshot.
The intermediate stays published. Both destinations must be fresh distinct
names in the same pinned directory. The sum of the two suffix lengths is at
most 4096 UTF-8 bytes. No new editor-specific code or additional operation
was needed for the second plan. The validator resolves operations by skill ID
and version, requires a linear single-use dependency and checks port types
and grants. Arbitrary user graphs are outside the CLI contract.

```powershell
$tag = [guid]::NewGuid().ToString('N')
$a = Join-Path $env:TEMP "$tag-a.txt"
$b = Join-Path $env:TEMP "$tag-b.txt"
.\target\release\reflexcore.exe agent compose-text winforms-background $a ' draft' --then $b ' reviewed' --create --verify --consume --derive --publish
.\tasks\Test-TextComposition.ps1 -Chain -AllowInput
cargo test --locked composition::tests
```

Cancellation probes place an isolated stop marker at ten boundaries in the
same native path used for dispatch, staging and publication. The test joins
the marker writer before execution resumes. A synthetic producer exercises
the editor-action boundary; the ten cases do not simulate a blocked live UIA
provider. Stop is cooperative between bounded writes and around readback,
sync and rename. An in-flight synchronous OS operation can finish. CLI
failure receipts report the count of already published outputs. Process death
may leave private staging or preclude a terminal receipt. There is no wildcard
cleanup of staging remnants and no automatic replay.

Next Phase C checkpoint: bind an immutable queue approval to graph version,
editor, suffixes, exact destinations and attempt, drive real step progress in
Studio and serialize accepted cancellation against terminal publication.
Measure paired resource usage and qualify crash recovery before closing C.
Phase D begins only after C acceptance, with read-only candidate discovery;
admission needs a versioned operation with declared ports, capabilities,
adapter restrictions, verifier and independently validated fixture evidence.

## Phase C approved composition checkpoint

In Studio open Agent → Skill Library → Compose text. Choose an editor, destination and suffix. Enable the second copy to chain another verified output. Submit, select the pending task, then choose Approve selected and review its exact inputs. The queue shows progress and the terminal publication count when available.

## Phase C live acceptance checkpoint

The queue supervisor crash fixture waits for two independently verified publications and the worker sidecar, then terminates the supervisor before it can write terminal history. Two recovery passes preserve both artifacts and leave one interrupted receipt with unknown verification and no publication count. No pending or running manifest remains. This qualifies the crash interval without changing queue semantics.

The six-step Notepad composition succeeded once through Studio's supervised queue in 3703 ms and once directly in 2621 ms. Both checks independently reopened the owned Notepad source and two derived copies. The earlier direct foreground refusal remains a recorded negative result. No focus retries or changes to ownership, user-input priority or consent were introduced. Opt in using tasks/Test-Handoff.ps1 -NotepadFocus or tasks/Test-TextComposition.ps1 -AllowInput -Chain -Editor notepad on the interactive desktop.

The live CLI/queue comparison and the independent end-to-end manual-versus-graph baseline are documented separately in BENCHMARKS.md. The latter verified 30/30 attempts per arm under the same authority and durability checks. A second kill test stopped the supervisor after it had replaced the running manifest with the staged verified receipt, just before the atomic history move. Recovery preserved both publications, discarded uncommitted verification, and emitted one interrupted receipt. The fault injection is compiled only in the owned test fixture.

Interactive Phase C criteria are qualified. Check the final published Windows CI result before closing the release checkpoint.

The installed Intelligence Bridge MCP observes its configured developer worktree. This branch has its own declared checkpoint in a separate Git administrative directory, read using the pinned native observer. The existing MCP component fingerprint omits this branch's test and composition files. Treat a matching fingerprint as scoped and consult the modified acceptance sources when resuming. These integration limitations are deferred to bridge maintenance.

Once Phase C closes, begin 0.8.3-D with one read-only discovery command for a disposable unfamiliar application. Report only bounded candidate operations with application binding, typed ports, required capabilities and proposed verifier. Acceptance must reject an unknown binding, undeclared capability and missing independent verifier before the candidate is eligible for admission. Keep discovery outside the execution queue.
