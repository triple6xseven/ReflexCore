# Cognitive runtime

## 0.8 measurement milestone

### Native execution sessions

The owned interactive Windows Flow fixture can opt into one disposable
process per Flow with `REFLEXCORE_UIA_WORKER=session`. Standard CLI actions,
guarded user flows and the background save workflow retain their existing
execution policy. Studio Diagnostics reads the selected run's existing
benchmark record and shows discovery, initialization and readback costs.

The Flow owns the supervisor. It starts one worker, binds its session and
run IDs to the fixture HWND and PID, and permits one outstanding request.
Inside the worker, a single COM apartment and UI Automation instance live for
the session. Each action resolves the window and discovers its element again.
Only named set-value, assert-value and invoke fixture operations are eligible.
The existing action implementation checks mutation permission and ownership;
the existing Flow verifier binds Apply to a later Output readback.

Protocol v1 uses a four-byte little-endian length and a JSON frame, limited
to 256 KiB, over inherited stdin/stdout. A reply echoes the entire request
header, including capability, absolute QPC deadline and action sequence. It
carries a typed worker error or a sanitized action result and numeric phases.
An eight-byte monotonic publication timestamp follows the reply for timing.
It has no authority to verify the action. A bounded I/O thread lets the parent
observe cancellation and deadlines even if the child blocks on a provider or
pipe. Failure ends the Flow, kills its own worker and joins the I/O thread.
A non-inherited kill-on-close Windows job handle terminates the session worker
if the supervisor exits abruptly. Assignment is required before dispatch.
A later Flow creates a fresh session. There is no cross-run cache or automatic
mutation replay. No service, GPU, model or network listener is involved.

The deterministic Windows adapter emits an additive numeric field on each step of
`reflexcore.flow.execution.v1`. `adapter_us` sums monotonic time inside
`execute_scoped` across all attempts, including unsuccessful calls. It includes
window resolution, request preparation, worker startup, execution and reply
handling. Retry delays and orchestration outside the adapter are excluded.
The existing benchmark carries this field into the run-specific Studio evidence
view. Older records have no value. Task success still requires correlated effect
verification. The telemetry adds no process, model request or background timer.

### Development roadmap

The UIA parent now waits on its own Windows child process handle between
cancellation checks. Worker exit wakes the parent immediately. The same
run/action identifiers and independent readback still gate verification.
Studio's per-step adapter timing includes this wait. The adapter keeps a
fresh COM process for each action, including when a previous action timed out.

The benchmark now reports `fixture_ready_us` from the start of fixture
setup until the PID-owned window is found. The value includes process launch
and polling. Studio displays it for the correlated run. Typed window lookup
avoids converting a desktop observation to JSON on each readiness probe.

Next, evaluate a second owned workflow with independent disk evidence and
measure cancellation tails before extending session eligibility. Keep
Focused and Deep routing and learned cost estimates experimental
until held-out comparisons justify them. The present UIA workflow uses the
native Reflex path with zero model calls.

## Routing and verification

`reflexcore.goal.v2` accepts a `guard` with an exact window title and a value predicate for each graph state. The runtime binds one foreground HWND and process, uses its AutomationId selectors, and checks each source and destination state plus the final Goal. It refuses ambiguous windows and Flow-level window or ordinal path overrides. See [the two-skill manifest](../examples/guarded_goal.json). Use `agent plan examples/guarded_goal.json` for read-only planning and `agent run examples/guarded_goal.json --execute` with the test fixture in the foreground. File-based Save verification is demonstrated by the separate owned fixture adapter.

The simulator lives in `legacy_demo`. Use `legacy-demo status` or the existing `status` alias to read its original state format.

`reflexcore agent verified-demo --execute` plans two skills against an owned WinForms window. It verifies the editor value before and after preparation, checks that value again before Save, and reopens the exclusively created fixture file to verify the effect and the final goal. A changed precondition stops the next skill. An unresolved effect is never replayed. This is the first guarded Goal adapter. Existing v1 manifests still use their Flow contract.

The Rust Goal Agent validates a v1 manifest, builds a map of outgoing edges and runs deterministic shortest-path search. Edges with equal cost retain their stable skill-name order. The existing Flow executor checks UIA assertions and bounds retries. An ambiguous or unverified mutation cannot produce a verified outcome. Flow receives a private UIA response matched by schema, run ID and action ID. Direct UIA commands still publish their diagnostic snapshot. Set-value verifies through same-element readback. The owned WinForms fixture binds Apply to its independent Output check and pins UIA to the child HWND and PID. The built-in WinForms fixture exercises set-value, readback, invoke and a final independent output assertion.

The Rust Goal Agent and the PowerShell Notepad supervisor share the Studio task queue. The tray launches one worker at a time. Each Notepad Auto run resolves the foreground notepad.exe window using a freshly created filename, checks editor ownership and selects a supported editor method. The Visual route additionally sends an image to local Ollama and applies its evidence gate. A known cold model loads before opening the new editor. Headless mode supports synthetic vision tests. Input requires an interactive desktop. See [queue and recovery](QUEUE.md).

A new demo file is created exclusively. The executor requires an empty editor, uses UIA ValuePattern.SetValue or targeted Unicode EM_REPLACESEL on a recognized native child editor, verifies the editor value, sends a bounded Save shortcut, then checks the file with ordinal text equality. Existing tabs are outside the task contract. The test runner closes only the verified fixture tab and retains the synthetic file in the local fixtures directory. On failure the fixture remains available for inspection. Typing into the editor, queueing Save and model classification each supply different evidence.

## Incremental learning

The [local skill and learning experiment](LOCAL-SKILL-LEARNING.md) shares the Goal Agent planner and SQLite file. Its CPU-trained controller is evaluated in a separate lab command.

**Goal routes.** A SQLite database under data/private is opened read-only for planning and created on first execution. The primary key identifies a SHA-256 digest of the canonical goal and a skill slot. Each learning sample also carries the SHA-256 of the bounded flow contents and the effect verifier version. A terminal assertion is required. A changed goal or flow ignores old evidence. A transaction records the outcome and evicts the least recently updated rows beyond 256. At 64 observations the counters decay together. Planning applies a bounded penalty proportional to misses divided by one plus passes. The manifest supplies the initial costs and allowed edges. A busy or unavailable database falls back to those costs. The execution report and permission checks remain authoritative for each run.

**Notepad.** At most two small descriptors, one per known editor family, store the method, required permission, effect, verifier and verified count. A hit bypasses editor discovery after validating the current foreground editor. Each execution checks the actual saved file. Failed tasks do not promote a new method. The supervisor's process mutex serializes writers, and replacement is atomic. The single-record format keeps this route usable without starting a Rust child or opening SQLite.

Both mechanisms learn on task completion. Model weights stay fixed. The calibration benchmark uses synthetic inputs and reports local generation throughput, cold latency, warm latency and sampled residency separately.

## Interface and resource use

Companion & Widgets can launch an isolated Godot renderer and manage Classic independently. The renderer receives the tray's existing status and privacy-bounded window geometry. See [ReflexCompanion](REFLEXCOMPANION.md).

ReflexVision publishes bounded visual observations to the existing CS16 CLI and displays the same tracks in a live preview. The isolated Plant Drill derives navigation and completion from game-engine state. Studio exposes both tools independently. The tray HUD samples system CPU and RAM, NVIDIA GPU and VRAM when NVML is available, and recent generation throughput. See [ReflexVision](REFLEXVISION.md).

A WPF Studio window hosts the six existing WinForms operator pages through one WindowsFormsHost. The native tray/HUD remains independent. The appearance gallery constructs its controls on first use. See [Studio](STUDIO.md). The native diagnostics counters use GetSystemTimes and GlobalMemoryStatusEx. Their timer follows the embedded dashboard's visibility. Whole-system CPU is the busy fraction between samples, and available RAM is a system counter. The named process table has a narrower scope. Existing GPU polling runs when the diagnostics view is visible. No kernel driver is required.

## Boundaries of this release

The Notepad route handles new scratch files and fixed text. The planner executes user-supplied manifests over supported flows. There is no general natural-language desktop team scheduler, autonomous installation of newly discovered tools, or Qwen weight training. Benchmark coverage is limited to the published fixtures. The visual diagnostics, third-party applications and older Windows/Notepad combinations need broader acceptance testing.

### Citadel visible deployment diagnostics

Agent Observability and the local Agent log show the failing stage and reason.
**Export Trace** records the stage, error code, game phase, elapsed milliseconds
and verified action count. It contains game coordinates and counters only.
The first deployment is verified against the game snapshot captured when
the unit is created. The 3D frame acknowledgement is checked separately.

Windows pointer mode still requires an explicit click. The browser scrolls
to expose the card and destination. Moving or zooming the window after
calibration, covering a target with another window, or taking over the
mouse terminates the session. Resize the window or zoom out if the deck
and drop point cannot fit together. Browser PointerEvents are also
available with the Windows pointer checkbox clear.

## Native handoff verification

[Verify a Handoff Folder](HANDOFF-FOLDER.md) runs from the CLI or the supervised Studio queue. Rust checks a typed checklist through native filesystem I/O and independently verifies the local report. The task needs zero model calls.

## Agent execution mode

Studio **Agent** has a **Background: On / Off** toggle above the task buttons, including when the queue is empty. Off uses Active window mode. The preference is saved in local project settings. The default is Active window. A queued job retains its selected route. In Background, folder checks and approved renames continue through the existing native filesystem workers. **Run Agent Demo** starts a transparent, non-activating owned WinForms fixture. UI Automation targets its window handle and process ID through Value and Invoke patterns, then independently reads the saved file. The worker uses no screen capture, pointer or keyboard injection, or model calls. Both Notepad demo buttons require Active window. Changing the setting affects future submissions.

The background fixture uses the current unlocked Windows session. It does not add background support to arbitrary applications or create an isolated desktop. Applications with a reliable native API or an explicitly tested UIA adapter are candidates for future background routes. Shared Control and user-defined UIA flows keep their existing foreground checks.

Run `tasks/Test-Queue.ps1 -UiaFixture` after building the release executable. The test compares the foreground window at each poll and requires a verified receipt from the background fixture.
