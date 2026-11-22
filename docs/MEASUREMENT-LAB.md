# ReflexCore 0.6.1 Measurement & Intelligence Lab

## Purpose
Measure verified goal completion before optimizing. This package **does not** change the
Rust planner, model weights, Citadel, mouse bridge, or existing Windows safety policy.
It extends an installed, Windows-validated `0.6.0 FIXED3` source tree.

### Fixed benchmark: `windows-uia-fixture-goal-v1`

1. Rust `reflexcore.exe agent demo --execute` reads the existing `examples/goal_agent_demo.json`.
2. Cost-aware goal planner selects the declared `demo` flow.
3. Existing Flow Engine opens the **real** `ReflexCore Test Window` (WinForms test fixture).
4. Existing Windows UIA executor performs `set-value`, `assert-value`, `invoke`, `assert-value`.
5. Execution passes only when the Flow report is **new**, has `outcome=passed`, has all four steps, and Rust exits with code zero.

The benchmark is interactive and must be authorized with `-AllowVisibleUI`. It opens a
known, locally created fixture window; the operator should avoid interacting with the
fixture during a run. It does **not** send physical mouse events. No LLM/Qwen is invoked.
When a run fails or times out, **that run is not counted as a successful fast run**.
The command exits nonzero when any measured run fails. The existing Rust Flow lock and
its safety controls remain authoritative.

`tools/Run-ReflexBenchmark.ps1 -Runs 5 -Warmups 1 -AllowVisibleUI`

The runner uses monotonic .NET Stopwatch for total wall time; measures Rust root-process
CPU milliseconds, peak working/private memory and samples its resource trajectory.
Because UIA workers and the WinForms fixture are separate processes, the root-process
CPU/RAM fields are **not a full process-tree total**. Whole-GPU accounting is available in the dashboard if NVIDIA tools are installed, but not attributed per process.
The start/end observation from the underlying Flow report is trusted; a simulated
state transition, HTTP dispatch, or changed pixel alone is **not** accepted.

### Numbers
- `total_ms`: elapsed from launch of Rust Goal Agent through process exit (fixture startup included).
- `flow_ms`: elapsed time logged by existing Flow Engine, including UIA steps.
- `non_flow_ms`: `total_ms - flow_ms`, **not** pure planning latency. Includes process startup,
  fixture startup and other overhead.
- `steps[].duration_ms`, `attempts`, `status`, `verification`, `evidence`: existing Flow
  structural evidence plus deterministic safety explanation; contains no selectors/values.
- `p50_ms`, `p95_ms`, `mean_ms`: successful measured runs only; failure count separately reported.
- `fixture_sha256`: composite fingerprint of three fixed fixture files. A different
  fingerprint means timing comparison is invalid until manually reviewed.
- `rust_sha256`: Rust binary fingerprint. A new SHA may reflect an optimization, but
  a faster measurement is not proof of general intelligence.
- `cpu_total_ms`: root Rust process CPU consumed over run, not entire system.

Warmups are **real verified UIA runs**, excluded from statistics. Both warm and measured
runs can steal focus temporarily. Use multiple sessions and evaluate variability rather
than relying on one fast run. Optimize **goal-success rate first**, then latency.

### Paths (private; outside the Git repo)
`%LOCALAPPDATA%\ReflexCore\diagnostics\measurement-lab\`
- `progress.json` — currently running benchmark stage, schema `reflexcore.benchmark.progress.v1`
- `history.jsonl` — bounded per-run metrics, schema `reflexcore.benchmark.run.v1`
- `runs/<opaque-id>.json` — timing/resource sample series and filtered Flow evidence
- `session-<opaque-id>.json`, `latest-session.json` — session summary, schema `reflexcore.benchmark.session.v1`

History rotates at 1 MiB. Nothing auto-uploads; no screenshots, input values,
private titles, prompts or raw model output are saved. Trace only includes allowed
action class, result code, time and verification evidence.

### Read-only diagnostics window
`tools/Start-ReflexDiagnostics.ps1` or `tools/Start-ReflexCore.ps1 -Mode Diagnostics`
opens a WinForms dashboard with run history, timing bars, per-step evidence and
current named process groups (`reflexcore`, `ollama`, `ollama_llama_server`).
CPU is normalized against total logical processors; memory is process working/private
bytes. It does not claim to include generic PowerShell/WinForms child processes.
An optional asynchronous `nvidia-smi` probe reports **whole-GPU** utilization, used VRAM, temperature and power when supported; it does not attribute GPU activity to the agent.
The Qwen tab reads **existing** `%LOCALAPPDATA%\ReflexCore\diagnostics\nav-performance.jsonl`
when available and marks its results as real Shared Control navigation-cycle telemetry,
not the fixed UIA benchmark. The button to run the fixed benchmark prompts the operator
before opening the fixture.

### Comparison and sanitized export
- `tools/Compare-ReflexBench.ps1` compares two recent compatible fixture sessions.
  Compare only if both are verified and results use the same exact fixture hashes.
  A low run count or mixed successes is a warning, never a claim of acceleration.
- `tools/Export-ReflexDiagnostics.ps1 -LastRuns 12` creates a **strictly allowlisted**
  ZIP of metrics, step codes and limited Qwen timing for sharing with an AI engineering
  assistant. The ZIP contains only one generated JSON, and never includes raw files.
  The operator must review before sharing. No external network use.

### Optimizaton experiment protocol
1. Run a clean 5–10 sample baseline; keep successful session JSON.
2. Change **one** code path: fixture launch, UIA discovery/cache, action worker startup,
   planner path, model prompt size, etc. Record the Git commit/hash in CHANGELOG.
3. Repeat the **same** fixture, warmups and machine power settings.
4. Check `success/attempts`, p50/p95, step breakdown and process metrics.
5. If `non_flow_ms` dominates, optimize launcher/fixture/startup rather than Rust IPC.
   If `steps[]` dominates, profile UIA worker startup and caching.
   If Qwen `infer_ms` dominates a separate navigation test, test quantization/context,
   reuse of observations and prompt optimization with equal success/verification.
6. Reject optimizations that lower verified success even if they make total time smaller.

## Validation status
User confirmed 0.6.0 FIXED3 installed: 71 Rust tests, seven JS regression suites,
C# self-tests, real Rust HTTP/IPC handshake. Synthetic Rust IPC p50=0.211ms,
p95=0.280ms and cold-start=17.527ms on that session.
0.6.1 Measurement Lab GUI and task repeatability are **not yet validated on the
user's Windows computer**. The installer runs only non-interactive, read-only self-tests.
