# Cognitive runtime

## Routing and verification

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
