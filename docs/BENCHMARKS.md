# Windows acceptance measurements

## Native UIA execution sessions

Run `cargo build --release --locked` and then
`tools/Measure-NativeSession.ps1 -AllowVisibleUI` on an unlocked Windows
desktop. The harness runs the same executable in A/B/B/A blocks. A uses
one UIA process per action. B reuses one isolated UIA process per owned
Flow. Each block excludes one verified warmup. A four-action run uses the
historical Goal, writes the fixture input, checks it, invokes Apply and
checks the output independently. A single action reads the initially empty
input. The 20- and 100-action fixtures append independent UIA output reads
to the four-action Flow. This characterizes reuse on a stable target.

The phase breakdown uses monotonic Windows QPC microseconds. Parent request
preparation and window resolution precede dispatch. Spawn time measures
the process creation call; spawn-to-worker-entry includes it and the child
loader. Do not add these overlapping values. The child measures COM entry,
UIA instance construction, element discovery, operation and readback.
Operation includes capability queries and dispatch. Readback includes result
construction after the provider call. Response writing covers serialization
and publication. Parent validation includes reading the disposable response
file; for sessions, the I/O thread decodes the bounded frame before waking the
parent. The child publication stamp splits response handling from exit or
acknowledgement. Session shutdown is recorded once per Flow. Root and child
CPU are cumulative Windows process counters and may have coarse resolution.
Aggregate private memory sums adjacent samples of the live parent and worker.
These samples exclude the PowerShell fixture, the benchmark harness and
Studio. They can miss short-lived memory peaks.

Latency percentiles use nearest rank. The denominator for verified runs
includes all measured attempts. Local session IDs identify the run records
in Measurement Lab. Compare selected sessions again with
`tools/Compare-NativeSession.ps1 -Sessions $ids`. Compare inputs and the
binary hash before combining runs. Per-action percentiles pool completed
actions. Zero model calls follow from the native execution path. Each run
starts a fresh parent and fixture. System caches and desktop load are uncontrolled.

## UIA worker exit notification

On the reference Windows laptop (Ryzen 5 4600H, 8 GB), compare the parent
sleep loop at `c101774` (A) with waiting on the child's process handle (B).
Use the same interactive desktop and fixture. Build with
`cargo build --locked --release` at each revision and run
`tools/Run-ReflexBenchmark.ps1 -Runs 5 -Warmups 1 -AllowVisibleUI` in
A/B/B/A order. Each attempt starts a fresh fixture and four disposable
workers. Each session excludes one warmup. OS caches were uncontrolled.

| Session | Build | Verified | Total p50 / p95 (ms) |
| --- | --- | --- | --- |
| 48e737a532994670 | A | 5/5 | 1092.18 / 1093.06 |
| b078bc8432504af7 | B | 5/5 | 1039.63 / 1107.71 |
| 08d807fc10044fe7 | B | 5/5 | 1041.72 / 1063.02 |
| 3c1559df5ef74b19 | A | 5/5 | 1107.81 / 1130.63 |

Across ten measured runs per build, nearest-rank total p50/p95 went from
1092.18/1130.63 ms to 1040.01/1107.71 ms. Flow p50 went from 516 to
480 ms. Median fixture readiness was 466 ms for both builds. Maximum sampled
root-process private memory was 1.42 MiB for both. All 20 measured runs
verified the expected output; the deterministic route made zero model
calls. With ten samples p95 is the slowest observation. The first candidate
session had a higher maximum than the first baseline session. These results
cover one workflow and do not establish general tail latency or child memory.

Fixture SHA-256: `7A4BEB5A153067E6CC69C5B4503E60BA0F647433AC224CC6930F3B989557F36A`.
Binary SHA-256 A: `39FF7980FA818A970AFB41A4F07B5DD5AEAE63A3205207C99F664DCBD7D29545`.
Binary SHA-256 B: `12E08AA9B4833065ADE80854775392E39B20EA0DDC5C1E87A95318582A4189E8`.

## Fixture readiness breakdown

Windows 11 Pro, Ryzen 5 4600H, 8 GB installed. The same CPU-only fixture and
verification gate were used throughout. Each session had one warmup, five
measured launches, five verified results and zero model calls. Nearest-rank
p95 is the maximum at this sample size.

| Session | Total p50 / p95 ms | Mean ms | Flow p50 ms |
| --- | --- | --- | --- |
| Baseline at `3e48482` (`cff323b9736b4483`) | 1154.68 / 1248.64 | 1168.73 | 519 |
| 50 ms readiness polling trial (`95e5615d5f934666`) | 1195.02 / 1742.02 | 1360.19 | 598 |
| Typed lookup and readiness timing (`ced43fd6e29c4e6f`) | 1084.51 / 1091.39 | 1076.60 | 498 |

Final fixture readiness p50/p95 was 465.48/466.47 ms and sampled root Rust
peak private memory was 1.42 MiB. Readiness includes launch and polling.
Baseline readiness is unavailable. The 50 ms trial showed no end-to-end
gain and the 150 ms interval was restored. The final median was 70.17 ms
lower than the baseline in these sequential sessions. Uncontrolled desktop
load and sample size prevent attributing the difference to typed lookup.
Run the same build and interactive benchmark commands shown below at each
revision. Inspect Fixture ready in Studio Diagnostics under Evidence / decisions.

## UIA adapter timing on the reference laptop

Windows, Ryzen 5 4600H, 8 GB installed. The owned four-action Windows Forms
Goal ran on CPU with zero model calls. Each series had one excluded warmup
and five measured launches, each with a fresh fixture and fresh UIA workers.
Percentiles use nearest rank. With five samples p95 is the maximum. Cold OS
cache and GPU usage were not measured. All 15 measured goals verified.

| Build | Session | Total p50 / p95 ms | Mean ms | Flow p50 ms | Sampled root peak private MiB |
| --- | --- | --- | --- | --- | --- |
| Existing release binary | 5f3e00cbccd54430 | 1056.59 / 1083.83 | 1061.48 | 495 | 1.42 |
| Experimental process-handle wait | ee316a0ccf3d4e9e | 1128.06 / 1305.80 | 1176.14 | 542 | 1.41 |
| Shipped instrumentation | e20dd0e878f24daa | 1109.44 / 1144.25 | 1106.96 | 518 | 1.41 |

The baseline binary's Rust sources match the feature branch base. All sessions
used fixture SHA-256 `7A4BEB5A153067E6CC69C5B4503E60BA0F647433AC224CC6930F3B989557F36A`.
Sessions ran sequentially on an interactive desktop. Load and filesystem cache
were uncontrolled. The measured median increased by 52.85 ms. These data
cannot attribute that difference to timing instrumentation. Replacing the
25 ms worker poll with a timed process-handle wait showed no end-to-end gain
in this trial and was dropped. Roughly half of the median task time is outside
Flow. That interval also includes planning and PowerShell fixture startup.

Reproduce at each revision with `cargo build --release --locked` then
`powershell -ExecutionPolicy Bypass -File tools/Run-ReflexBenchmark.ps1 -Runs 5 -Warmups 1 -AllowVisibleUI`.
In Studio, open Diagnostics, select a run and open Evidence / decisions.
Each run keeps its binary hash, fixture hash and action results locally.
Adapter round trips include retries and worker overhead. They are part of
step elapsed time. The peak memory column covers sampled root Rust memory only.

The UIA Goal benchmark passes a unique run ID to each owned subprocess. It accepts the run-scoped report only when its schema and ID match and the subprocess succeeds. The latest Flow snapshot stays available for local diagnostics. Run `tools/Run-ReflexBenchmark.ps1 -SelfTest` to check the fixture and rejection of unrelated or truncated reports.

## Supervised task stop and receipts

Windows synthetic comparison with eight runs per revision, using the same queued PowerShell worker and the same legacy stop-all command. The worker polls a cancellation marker and acknowledges it before returning. The harness measures the command handler on the WinForms thread and polls for the terminal queue entry every 20 ms.

| Revision | Terminal p50 / p95 | Handler p95 | Cooperative acknowledgements |
| --- | ---: | ---: | ---: |
| 3ec8e09 | 206.41 / 1158.29 ms | 1154.50 ms | 0/8 |
| Correlated receipts and cooperative stop | 160.88 / 342.79 ms | 30.00 ms | 8/8 |

The harness observed a WinForms timer tick before the terminal entry in all eight runs per revision. This measures progress in a controlled UI event loop. Handler latency separately measures where the baseline could block that loop. Candidate poll p95 was 69.69 ms. These measurements are synthetic and do not estimate cancellation latency for real UIA providers or model unloads. Reproduce with `tasks/Measure-TaskStop.ps1 -Runs 8`, passing the baseline checkout to `-SourceRoot` for the comparison.

## CS 1.6 automatic plant routing

### Fresh-round and recovery validation

The earlier Inferno failure reproduced on the isolated server: one movement command was followed by `PoseDiscontinuity` and no plant. The controller now waits for a changed, live round generation and pairs it with the exact observation tick. Automatic steering and path simplification use stricter geometry checks. The engine's confirmed plant-zone flag can complete navigation early when the pose is valid. This fixed the Aztec case in which the player had entered the valid zone while the next planned waypoint still appeared unreachable.

The test uses a stationary CT fixture on loopback. `Test-CS16AutoRoute.ps1` additionally checks the fresh GoldSrc log for a plant by the same owned actor. `de_train` was selected before tuning the candidate and was held out from route/steering tuning. Count match wins separately. The four controller runs below use one observed spawn per map and do not establish arbitrary-map or arbitrary-spawn reliability.

| Map | Engine-confirmed zone and independently verified plant | Total wall time | Recovery attempts | Spawn to plant from game log |
| --- | --- | ---: | ---: | ---: |
| de_inferno | Yes | 46.84 s | 0 | 44 s |
| de_train (held out) | Yes | 39.75 s | 1 | 38 s |
| de_dust2 | Yes | 42.80 s | 1 | 41 s |
| de_aztec | Yes | 48.81 s | 1 | 46 s |

A separate Studio-panel run with Record replay enabled verified the Train plant again (40.2 s, one recovery) and saved a 389,117-byte HLTV demo. The plant was independently verified for the actual actor ID in the GoldSrc log.

The earlier Dust II and Aztec totals below were shorter. The candidate uses smaller steering corrections and preserves more waypoints in narrow areas. These are single-run comparisons and do not isolate the cost of each change.

Tested on the owned localhost GoldSrc server with a stationary CT fixture. These trials start from the actual actor spawn and use auto-discovered bombsites. The pass criterion is a fresh C4-plant acknowledgement from the engine.

| Map | Verified C4 | Navigation | Total | Movement commands |
| --- | --- | ---: | ---: | ---: |
| de_dust2 | Yes | 28.55 s | 36.63 s | 258 |
| de_aztec | Yes | 31.00 s | 39.96 s | 269 |
| de_inferno | Initial route and same-site recovery stalled | 26.98 s | 33.62 s | 172 |
| de_inferno (alternate-site build) | Stopped after a pose discontinuity | 0.04 s | 6.63 s | 1 |

The static walker found routes from a representative spawn on Dust II (24 waypoints), Inferno (25), Aztec (25) and Nuke (24). It refused Office because the map has no brush bombsite. A successful static search does not verify an executable path. The full-match win benchmark remains the separate de_reflex_lab baseline.

Across the real local map trials, 450 of 459 forward pulses produced plausible acknowledged movement. Acknowledgement latency was 110 ms p50 and 114 ms p95. Readback failures and discontinuities do not count as successful movement.

## Local learning experiment

Windows release build on AMD Ryzen 5 4600H. Training seed 701242, final evaluation seeds 710352 and 710362, 256 independent cases per fixture, common cases across policies. Ground uses an approximately linear pulse response. Arena uses a nonlinear response and a different delay effect. The source-only policy enters Arena with an unchanged Ground checkpoint and no Arena training. Inputs are normalized distance, measured progress and delay, with no map coordinates.

| Fixture and selector | Success | Failed | Overshoots | Mean simulated duration | Mean CPU decision |
| --- | ---: | ---: | ---: | ---: | ---: |
| Ground fixed | 244/256 | 12 | 125 | 608.9 ms | 36 ns |
| Ground untrained MLP | 206/256 | 50 | 0 | 922.7 ms | 122 ns |
| Ground adaptive, model-free | 256/256 | 0 | 0 | 528.4 ms | 39 ns |
| Ground trained with replay | 256/256 | 0 | 0 | 531.8 ms | 170 ns |
| Arena fixed | 242/256 | 14 | 0 | 677.2 ms | 38 ns |
| Arena untrained MLP | 166/256 | 90 | 0 | 1053.7 ms | 120 ns |
| Arena model trained only on Ground | 256/256 | 0 | 0 | 530.6 ms | 157 ns |
| Arena adaptive, model-free | 256/256 | 0 | 0 | 530.6 ms | 38 ns |
| Arena trained with replay | 256/256 | 0 | 0 | 533.2 ms | 164 ns |

Durations include simulated settle time and a probe where used. CPU decision times are approximate microbenchmark averages and include timer overhead. The adaptive and neural paths have the same measured-gain safety limit. The overshoot counter counts crossing the target outside tolerance. The trained checkpoint passes the lab gate against fixed pulses and changes the outcomes of the untrained network. It does not outperform the simple adaptive rule across both fixtures.

The two training phases took 3.177 ms and 3.712 ms, measured on the CPU path in a standalone process with a 7,143,424-byte peak working set (6.81 MiB). No GPU calls were made. This is not a system VRAM measurement. The checkpoint contains 87 parameters and takes 1,036 bytes serialized. Baseline weights SHA-256 `46da14fd42f372210bd6f354e750fb0f4dbdb700243e9f152be557a5f8243093`. Candidate SHA-256 `ab902e569d79bfcc384ad11d5c75dffa57a668dadd0d213d6ffba80bbeb26497`. Real-game and Windows task performance are outside this transfer benchmark.

Run `target/release/reflexcore.exe learning experiment` from the project root. See [mode configuration and checkpoint validation](LOCAL-SKILL-LEARNING.md).

### CS 1.6 regression baseline

The isolated `de_reflex_lab` match in the `2a61c29` implementation was independently rechecked from the GoldSrc console log using `cs16 benchmark <round.log> --player 2 --require-plant-kill-win`. The carrier planted at 13 seconds and defeated the owned CT with the Glock at 15 seconds. The team win and round closure were observed at 15 seconds. One verified round with second-resolution timestamps is a regression reference, not a success-rate estimate. The route runner follows a map-specific waypoint file, observes live pose and plant flags, and uses engine visibility for the match reaction. Studio gates this match preset to `de_reflex_lab`. The offline plant drill can take a compatible route for another map, but rejects a map mismatch.

Private artifacts under `data/private/cs16-baseline-v1` retain the route, map, anonymized one-round evidence, JSON metrics and demo. Map SHA-256 `6f125d6509ffc60d635a804abe64275b11a90e950abf66f51f591e3c86285163`. Demo SHA-256 `19f1cfe2218a50156365c6fb26fe1fc93eae1583296f104c92fbdb20037f2651`. Route SHA-256 `5cf4bd76b80327f1c30e38b59ec4ec4af0991be6430898ff834acace66e139a1`.


## ReflexVision capture maintenance

Windows visible fixture, 100 measured frames per run with eight warmups. Two pairs per capture mode, interleaved baseline `b19e4a8` and candidate. Each direct run reported 100 frames with tracks. Each CPU-scale run reported 85. Frame p95 includes capture, detection, tracking and painting.

| Path | p95 before, ms | p95 after, ms | CPU % of one logical core before → after |
| --- | --- | --- | --- |
| Direct | 14.57, 11.18 | 14.43, 19.60 | 18.44 → 18.16, 19.99 → 21.24 |
| CPU scale | 15.07, 13.82 | 15.21, 12.95 | 18.65 → 17.87, 21.73 → 19.90 |

The full pipeline did not show a consistent latency improvement. The isolated CPU resampling loop, scaling 800×600 to 480×360 after 40 warmups with 50 batches of 20 calls, changed p50 from 0.8399 ms to 0.1469 ms and p95 from 0.8979 ms to 0.1656 ms. The sampled-pixel checksum was identical. The microbenchmark used the same C# compiler switches on both versions and excludes capture, painting and target eligibility. Live CS 1.6 gameplay was outside this comparison.

## ReflexVision v0.1

The measurement host ran Windows 11 with a Ryzen 5 4600H, 8 GB of RAM and a GeForce GTX 1650 Ti with 4 GB of VRAM. Both paths used the classical detector and the same 480-pixel output width. Eight warmup frames preceded each measurement. The full-copy path used GDI for the copy and CPU code for scale. The direct path used a single scaled GDI blit to the detector buffer. The path name makes no claim about the display driver's hardware acceleration.

| Scene and path | Frames | FPS | Capture-to-paint p50 / p95 | CPU % of one logical core | Process peak |
|---|---:|---:|---:|---:|---:|
| Moving WinForms fixture, scaled GDI | 100 | 15.92 | 9.38 / 10.94 ms | 17.16% | 98.19 MiB |
| Moving WinForms fixture, copy + CPU scale | 100 | 15.90 | 10.09 / 11.56 ms | 21.36% | 99.78 MiB |
| Windowed local Dust II, scaled GDI | 120 | 15.52 | 29.97 / 38.89 ms | 23.85% | 105.68 MiB |
| Windowed local Dust II, copy + CPU scale | 120 | 15.90 | 28.60 / 36.54 ms | 22.77% | 108.96 MiB |

The fixed benchmark cadence caps throughput. Working set includes the PowerShell host. During the CPU-scale game run, three device-wide NVML readings showed 587–623 MiB of 4096 MiB allocated and 11–14% GPU activity, including CS 1.6 and the desktop. A nearby reading outside the trials was 599 MiB and 8%. Neither series isolates the preview's VRAM use. Both paths used CPU inference. In the game run Rust accepted four confirmed HUD boxes in a live 480×360 observation. The independent stop signal closed the live preview and Rust rejected the stopped observation.

### Offline GoldSrc Plant Drill

Three fresh server launches on the original de_reflex_lab map produced three verified plants. Navigation took 8.546–8.580 s, planting 4.154–4.162 s and total wall time 14.764–14.796 s including setup. Each attempt sent 78 move and 36 plant pulses. The fresh GameDLL logs independently reported 13 seconds from spawn with C4 to plant at one-second resolution. The opponent was stationary. A fourth run cancelled during navigation after five move pulses and exited 208 ms after the stop request, with no attack pulses and the mailbox lock released.

## 0.7.1-alpha.2 · Desktop queue and focus

Windows 11, same 8 GiB / 4 GiB GPU host. The native Notepad fixture verified 20/20 files, with 20 memory hits, zero model calls and p50/p95 of 746/766 ms. Timing starts inside the supervisor. It excludes time waiting in the queue. The previous series measured 752/890 ms. These small series establish correct reuse on this host.

Submitting a manifest via the earlier Studio PowerShell child took p50/p95 of 416.13/739.00 ms. In-process submission took 1.75/2.96 ms. Each route produced 20/20 valid manifests in alternating order after one excluded warmup, on a temporary local directory. Run tasks/Measure-Queue.ps1 to reproduce. This measures creating a pending entry. Tray polling, worker launch, UI execution, rendering and cloud-folder synchronization are outside the interval.

In one early mixed queue trial the second Notepad task failed to finish successfully. The test did not capture the failing stage. Four subsequent full mixed runs completed both real Notepad files and the intervening Rust UIA goal, followed by another passing release check. Each successful pair used two separate workers and zero model calls. The targeted cancellation test stopped during real local 2B inference. Its file remained empty. Two runs observed 320 ms and 143 ms from the cancellation request to the terminal receipt, including client and model cleanup.

On the earlier 4B route one run rejected the editor. An instrumented repeat observed the owned editor before inference and a different foreground afterward. Preloading the cold model before launching the editor gave three successful disk readbacks in 37.77, 31.33 and 31.37 s. The final build repeated the test in 32.10 s. All four returned an editor-positive model answer with a conflicting application label. Windows ownership checks and exact file contents supported the successes. The observed focus change has no confirmed external cause. These runs do not measure general desktop vision accuracy.

The queue checks cover fresh approval, old claims, cancellation while another worker runs, process exclusion, nonzero exits, stop-all and bounded history. Studio smoke also clicks all three submit actions, selects a real row and verifies its approval and cancellation markers in an isolated store.

The alpha.1 baseline VisionLoop SHA-256 was `8dda8e5bd561ca158f2efb0bb32faa6b2ad76185a85f7d7253bd977f119547b5`. The alpha.2 VisionLoop SHA-256 is `ac04fb35fcee73945869b7cbd646a7f15bcca4646338c0c35c609c70a31d505e`. The baseline and candidate Control Center hashes are `63fe915fcdab5ea8b693a9b5222613e49fc43790c2a7a1bfde6b8e1764f59432` and `90b20941cca94bb9fe2f9e09c5b116c92684d8ca1c9b46e1ce64250a1e3614ac`. The queue implementation hash is `56d55ef1af2f18462c804589d7f554c505b65cb13275cb3190c1e0a6032f2b29`.

## 0.7.1-alpha.1 · Baseline and native routes

Local interactive Windows 11 host in the 8 GiB RAM / 4 GiB GPU class. Measurements use the installed Preview3 FIX4 source as baseline and a separately built candidate. Tests use synthetic data. This is an experimental release.

| Workload | Baseline | Candidate |
|---|---|---|
| Real Notepad, fixed ASCII task | 0/1 disk verification, exit after 38.6 s including PowerShell startup. UIA found an editor. VLM reported other / editable. | 20/20 disk verification in Auto, alternating ASCII and Unicode. 0 model requests. Warm skill, p50 752 ms, p95 890 ms. |
| Native Unicode fallback | Packet-input experiment failed the editor readback before Save on modern Notepad. | 1/1 forced native editor write verified from disk, including a supplementary-plane character. |
| WinForms Goal Agent, four UIA steps, 1 warmup + 3 measured | 3/3, p50 1,501 ms, p95 1,890 ms | 3/3, p50 1,108 ms, p95 1,277 ms |
| Plan a 2,048-edge chain, 20 paired process launches after two warmups | p50 42.0 ms, p95 58.2 ms | Identical plans, p50 32.4 ms, p95 55.1 ms |
| Release executable | 1,045,504 bytes | 2,788,352 bytes including bundled SQLite |
| Rust tests | 71 passed | 72 passed |

Notepad timings start inside the supervisor and include opening the document, verification and test-tab cleanup. The test runner reuses the PowerShell host across trials. The failed baseline supports a correctness comparison only. The early packet-input experiment narrowed the error to the text-entry stage. Its precise Windows-internal cause is undetermined. There is no successful baseline Notepad latency to use for a speedup claim.

The 2B Visual route also completed one real Notepad run and read back the file (one model request, 20.4 s). The 4B Visual run stopped when the foreground editor could not be revalidated after inference. No subsequent input was authorized for that run. The automated native route supplies the repeatable result.

The final WPF Studio displayed six hosted operator pages and the 45-theme appearance page. The prior WinForms Control Center also displayed all six actual pages and exposed the new Notepad task control. Citadel passed seven JavaScript suites and four syntax checks. The release executable served 30 synthetic JSONL IPC samples at p50 0.409 ms and p95 0.670 ms. IPC timing excludes GUI and model work. Explicit missing consent and headless input were rejected. Skill-memory tests cover corrupt, oversized, cross-family and unknown descriptors. Rust memory tests cover route changes, content invalidation and row bounds.

## Model comparison

Two passes over six fixed tasks per model, with context 2,048, temperature 0, seed 1 and at most 32 generated tokens. The first request starts cold. The other 11 requests include text and image work. Images are two colors and two labeled button layouts. The text prompts ask for a structured action. Response correctness is exact and checks the JSON shape.

| Model | Text | Images | Cold first request | Warm p50 / p95 | Generated tokens/s | Sampled model / VRAM MiB | Minimum sampled available system RAM |
|---|---|---|---:|---:|---:|---:|---:|
| Qwen3-VL 2B Instruct | 2/4 | 8/8 | 6.93 s | 0.31 / 12.25 s | 59.0 | 1,683 / 1,683 | 1,583 MiB |
| Qwen3-VL 4B Instruct | 4/4 | 8/8 | 11.57 s | 1.41 / 19.59 s | 9.1 | 3,496 / 1,748 | 782 MiB |

Model and VRAM figures come from Ollama's resident-model endpoint after requests. Host availability includes other processes. Generation rate excludes image encoding and prompt evaluation. An earlier comparison produced the same accuracy counts but different cold times. Model unload was checked between runs. The small repeated task set does not establish general GUI accuracy.

## Diagnostics overhead

One 8-second hidden and one 8-second visible interval per build in a fresh Windows PowerShell process, sampled at 50 ms. Numbers include the benchmark message pump. The candidate pauses the diagnostics timer while the embedded view is hidden.

| View | Baseline process CPU / peak working set | Candidate process CPU / peak working set |
|---|---:|---:|
| Hidden | 672 ms / 95.7 MiB | 547 ms / 91.4 MiB |
| Visible | 969 ms / 101.8 MiB | 891 ms / 101.4 MiB |

These short measurements include host scheduling noise. GPU overhead of the interface was not isolated. Models were benchmarked on the shared desktop, and some development or fixture activity overlapped. Reported maxima are sampled values.

## Reproduction

Run the following from the repository root in Windows PowerShell after the release build. The Notepad tests take foreground control of their own fixtures. The model comparison starts with an idle Ollama server and requires both tags to be installed.

~~~powershell
cargo test --locked
cargo build --release --locked
.\tasks\Test-SkillMemory.ps1
.\tasks\Test-NotepadSkill.ps1 -AllowInput -Runs 20
.\tools\ReflexCore-VisionLoop.ps1 -Action DemoNotepad -AllowInput -TestFixture -UnicodeFixture -TestNativeInput
.\tools\Run-ReflexBenchmark.ps1 -Runs 3 -Warmups 1 -AllowVisibleUI
.\tools\Benchmark-ReflexLatency.ps1 -Samples 30
.\tasks\Test-Citadel.ps1
.\tasks\Compare-LocalModels.ps1
.\tasks\Measure-Diagnostics.ps1 -Project . -Seconds 8
py .\tasks\compare_goal_planner.py <baseline-executable> <candidate-executable>
~~~


A second paired WinForms fixture run matched the five-run acceptance protocol with one excluded warmup. The baseline verified 5/5 at p50 1,087 ms and p95 1,156 ms. The final Rust engine verified 5/5 at p50 1,121 ms and p95 1,170 ms. Across the two series this fixture shows no repeatable latency improvement. See [Studio](STUDIO.md) for full-shell overhead.

## Compared source SHA-256 values

| Source | Installed baseline | Candidate |
|---|---|---|
| src/agent.rs | 5ce4fa8bcd4d6c2a3205c16938781a9c9fdcf1755feef5bfaf0682eea34ccea5 | 9b03aba9ec90886e93d27d96249b37b9d9e4dc9a49162d0859fa04a50b9d82af |
| tools/ReflexCore-VisionHost.cs | 68f8274d483ed98e85a924fedfbfcb01be23c96153ba445d1f9efc9e2dcde465 | c4bbf80d64a232ace719df836dc3ad2e27deee06834dc794c54923dba0c09a14 |
| tools/ReflexCore-VisionLoop.ps1 | dd618f74f8175ed89fbbf1440ee744530e6ba15615288be63e7aea2cee2fec49 | 8dda8e5bd561ca158f2efb0bb32faa6b2ad76185a85f7d7253bd977f119547b5 |
| tools/ReflexCore-Diagnostics.cs | 7796fd7a079406795dee809ae96a36c1547dcb82f6bbdd53ec505ce00b2b0ff1 | aaa80d3a8899a43eb207b2330e519849371aa27d84ec14c3fa1e6b179dcd7688 |

## Verify a Handoff Folder

Windows 11 Pro 10.0.26300, Ryzen 5 4600H, 8 GB installed RAM (7,915,913,216 bytes visible to Windows). The worker used CPU-only native I/O and SHA-256. The Ollama server was present with zero loaded models. All 48 measured receipts recorded zero model calls. The offline assertion can also be run with the server stopped.

Four paired sessions with identical synthetic filenames and bytes in both modes. Each mode starts a fresh isolated tray controller and fresh worker. Cold is the first run of a controller session. Warm is the next five runs, each with a new worker. The filesystem cache was left intact. Each manifest checked 100 entries. The hash variant read 12.5 MiB. The outer test reopened each report, checked its matching receipt and independently validated every requested digest.

All time cells are nearest-rank p50 / p95 in milliseconds. Queue wait begins at job ID allocation and ends just before supervisor launch. Startup includes the supervised PowerShell worker and Rust process launch. Total is the per-run sum of queue wait, startup, and Rust worker duration. Terminal history delivery after the worker exits is outside these timing intervals.

| Mode | Verified | Queue wait | Startup | Checking | Report write | Readback | Worker | Total | Peak private max |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Metadata cold | 4/4 | 11.1 / 56.7 | 408.7 / 480.7 | 18.9 / 20.2 | 6.8 / 8.2 | 9.5 / 12.0 | 38.4 / 42.3 | 461.0 / 575.7 | 1.25 MiB |
| Metadata warm | 20/20 | 5.0 / 6.6 | 412.8 / 480.5 | 19.1 / 22.8 | 5.7 / 9.4 | 9.8 / 14.5 | 36.6 / 49.3 | 456.1 / 519.8 | 1.26 MiB |
| SHA-256 cold | 4/4 | 10.6 / 11.4 | 403.2 / 736.8 | 58.9 / 83.6 | 4.7 / 6.4 | 10.0 / 11.1 | 75.3 / 100.2 | 489.7 / 848.1 | 1.37 MiB |
| SHA-256 warm | 20/20 | 4.7 / 6.4 | 408.4 / 602.4 | 59.6 / 87.6 | 5.8 / 20.1 | 11.1 / 13.8 | 76.7 / 110.0 | 490.5 / 720.0 | 1.38 MiB |

The metadata worker met the 1-second warm p95 target. The largest measured cost was launching the supervised worker. Effective hash throughput over the entire warm checking phase was approximately 210 MiB/s at p50 checking time and 143 MiB/s at p95 checking time. This includes file opens, scope checks, and cancellation checks. Worker private memory is the Windows peak commit charge of the Rust process. Release executable SHA-256 `aae4e0c9c737d77f684f6d4a6782568c036fe0fc9af3a613a680625daa2b8dc8`. Reproduce with [the handoff acceptance commands](HANDOFF-FOLDER.md#reproduce). Add `-MetricsFile` with a new file path to export run-correlated, path-free samples.


### Handoff checklist drafting

On the same Ryzen 5 4600H Windows host, a fixed evaluation set specified before implementing the parser produced 8/8 exact drafts, 7/7 clarifications, and 7/7 scope rejections. Across 440 warmed calls, parser p50 was 0.012 ms and p95 was 0.0223 ms. This includes PowerShell-to-.NET dispatch and excludes window interaction, queue wait and filesystem verification. The CPU parser makes zero model calls. The small set exercises the supported grammar and does not estimate accuracy on free-form requests.

## Dust II adversarial practice experiment

Windows 11, Ryzen 5 4600H, 8 GB installed RAM. The owned server ran GoldSrc protocol 48 on loopback with AMX Mod X 1.10.0.5488. The controller used zero model calls and no desktop input.

Five exploratory Dust II rounds on the first compatible snapshot protocol closed with an independently verified C4 plant and Terrorist win. They used one observed spawn. Two had pre-plant contact and a defender discharge. Two attack requests from the controller produced zero confirmed actor discharges, damage events or rifle kills. An initial setup attempt and a later batch of setup attempts exposed match snapshot compatibility failures. The raw reports remain private. The saved-route laboratory independently confirmed a plant, defender kill and win.

The vision pilot used two manually labeled archival client crops at 480x360. One showed a visible player and one showed the game console. Neither had a synchronized server tick. YOLOX-Tiny used the upstream ONNX checkpoint at 416x416. Its SHA-256 is 427cc366d34e27ff7a03e2899b5e3671425c262ea2291f88bb942bc1cc70b0f7. The upstream repository supplies Apache-2.0 licensing. At IoU 0.50 the raw detector matched one player, missed zero and returned two false boxes on the console frame. Precision was 1/3 and recall was 1/1. Supplying manual scene labels suppressed both console boxes. Replay latency p50/p95 was 65.606/65.905 ms raw and 3.353/70.886 ms gated. This pilot excludes live capture and tracking. [Checkpoint release](https://github.com/Megvii-BaseDetection/YOLOX/releases/tag/0.1.1rc0) and [upstream license](https://github.com/Megvii-BaseDetection/YOLOX/blob/main/LICENSE).

### Final five-round cohort

Runtime revision f27b62f481804b0655cf4fee5d3a7ff0cedc0d07. Release executable SHA-256 170FA133D7D2F5B6D25236B97029DDF6B7E0E3FFA1735E0B1AD8AFCCDA5B70CD. AMXX plugin SHA-256 86AC1BAB94E016DEFC117F80166D9F86850BDC49A177581D7B95455613C75616. All five fresh server starts selected the same observed Terrorist spawn (-832, -800, 177). This cohort provides no evidence of spawn generalization.

| Trial | Pre-plant contacts | Actor requests / discharges / hits | Defender discharges before / after plant | Log-confirmed plant / win | Worker elapsed (s) | Observation p50/p95 (us) | Decision p50/p95 (us) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1 | 1 / 0 / 0 | 1 / 0 | 1 / 1 | 79.230 | 425 / 1003 | 0 / 0 |
| 2 | 0 | 0 / 0 / 0 | 1 / 0 | 1 / 1 | 79.040 | 419 / 1025 | 0 / 0 |
| 3 | 0 | 0 / 0 / 0 | 0 / 0 | 1 / 1 | 78.378 | 392 / 1010 | 0 / 0 |
| 4 | 0 | 0 / 0 / 0 | 0 / 0 | 1 / 1 | 78.923 | 418 / 1015 | 0 / 0 |
| 5 | 0 | 0 / 0 / 0 | 0 / 0 | 0 / 0 | 21.127 | 389 / 595 | 0 / 0 |

Four of five rounds closed with a log-confirmed plant and Terrorist win. No actor kill or death was observed. In trial 5, route recovery exhausted its budget after a stall before reaching A; the benchmark rejected the run because no plant was independently verified. In trial 1 the controller reached contact and issued a shot request, with no confirmed discharge. Two pre-plant defender discharges were measured across the cohort. Post-plant defender discharge remains unverified. Across implementation iterations there were 16 ordinary Dust II attempts: six setup failures, five exploratory plants and wins, and these five final attempts. The cancellation and regression trials were separate.

Observation percentiles summarize synchronized snapshot reads, including retries, with 296 to 2,563 samples per attempt. Decision percentiles summarize the local branch only, excluding action acknowledgment, with 148 to 1,281 samples. Values of zero are below microsecond reporting resolution. The maximum sampled Rust worker working set was 7.16 MiB; GoldSrc, HLTV, and Studio were outside this measurement. The first trial produced an HLTV demo with a valid GoldSrc header, Dust II map name, and finalized directory. Interactive playback was not tested.

The separate active-round stop reached a cancelled outcome after one acknowledged move and zero attack requests or plants. The stationary Dust II Plant Drill passed with fresh server-log evidence. Cargo tests passed 120/120. AMXX compilation, the practice launcher self-test, Studio UI smoke, and the eight-scene synthetic scorer fixture passed.

## MCP workflow pilot

One local zxcLagLab release presence check matched all four configured files. The queue receipt and independent report agreed on the run ID and Ready verdict. The Rust worker took 20.661 ms, including 8.110 ms for readback. Worker startup took 428.860 ms. Peak worker private memory was 1,232,896 bytes. Zero model calls and zero checksum bytes were recorded. Single-run figures do not estimate tail latency or validate the executable itself.

Two owned Dust II attempts exercised the MCP evidence publisher. The older installed plugin rejected setup; the record reported infrastructure failure and a null winner. After temporarily installing the current compiled plugin, the log confirmed one closed Terrorist win and plant. The controller recorded one contact, one shot request, zero actor discharges, and zero hits. Observation p95 was 2,876 microseconds across 2,607 samples. This pilot measured evidence reporting and did not demonstrate improved combat.

## Offline AK-47 combat fixture

Windows 11 Pro, Ryzen 5 4600H, 8 GB installed RAM. Owned HLDS file version 4.1.1.1, AMX Mod X 1.10.0.5488, practice plugin 1.3. The suite used an identical server, GameDLL, BSP and candidate adapter binary for baseline and candidate. Initial spawn positions were pinned. Engine RNG and scheduling were uncontrolled.

Final suite ID `961f3f4b64ca4459ab3df4c1c3c795c2`. Digest provenance is recorded in its private suite header. Published build SHA-256 values:

| Component | SHA-256 |
| --- | --- |
| core | `ff9fef4d6af64924ec81d436d1f4c3a8e564ec3f34c8ddd6e8a7653d17b2ed88` |
| plugin | `93342945a403622f9183670f42b463d2743f6429b052962a91b3e846894aaa43` |
| server | `bd5b37ec60301ff243beb114cbb69bf5213cbc3330496226558df912349ac96d` |
| game_dll | `1de43e39dc9b085d5b0fe7920c520a319a8244532835c9ef7a4f5da930bace54` |
| map | `6f125d6509ffc60d635a804abe64275b11a90e950abf66f51f591e3c86285163` |

Times measure dispatch through mailbox acknowledgement. They exclude the deploy wait and capture-to-decision latency. The separately reported observation age is engine snapshot to request acceptance.

| Scenario | Policy | Run ID | Result | Requests | Discharges | Damage events | Selection errors | Request to ack (ms) |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| stationary | baseline | `26b9dc465db24c089cdd5b214247ce74` | weapon_timer_active | 1 | 0 | 0 | 0 | 109.837 |
| stationary | candidate | `08cd5b2bb8d64e9eaa832af82cc39dd9` | clip_decreased | 1 | 1 | 0 | 0 | 114.644 |
| moving | baseline | `cc2f9cb436de49d3a39a5fe11327d3cf` | weapon_timer_active | 1 | 0 | 0 | 0 | 109.898 |
| moving | candidate | `d046f6a45ee14221a3644f21f8f950a2` | clip_decreased | 1 | 1 | 0 | 0 | 113.153 |
| friendly | baseline | `f49e6f848b83447da7a5b9b1e527961d` | friendly_target | 1 | 0 | 0 | 0 | 109.538 |
| friendly | candidate | `ea166a3979c84a2dab2906fda83cc6bd` | friendly_target | 1 | 0 | 0 | 0 | 110.033 |
| occluded | baseline | `36c0692ee73048f78af9c0074a9a3881` | occluded_target | 1 | 0 | 0 | 0 | 110.391 |
| occluded | candidate | `a91e3936870f4d2d9c42a084c83d126e` | occluded_target | 1 | 0 | 0 | 0 | 110.435 |
| heldout_moving | baseline | `312edbccf38e472bacdfd0861042c9ca` | weapon_timer_active | 1 | 0 | 0 | 0 | 111.722 |
| heldout_moving | candidate | `e42dadfbc2c24eebb6c6f0b74649233d` | clip_decreased | 1 | 1 | 0 | 0 | 110.133 |
| heldout_occluded | baseline | `3434d563457d4fe0823ff8163d741e03` | occluded_target | 1 | 0 | 0 | 0 | 109.821 |
| heldout_occluded | candidate | `c21f687f18574068bb09b52f4e7d48bb` | occluded_target | 1 | 0 | 0 | 0 | 110.495 |
| stationary | candidate | `f7a720d0350b4dabb62456a020e178ec` | cancel_barrier | 0 | — | — | — | — |

Nearest-rank request-to-ack p50/p95 were 109.837/111.722 ms for baseline and 110.435/114.644 ms for candidate, with six samples each. Observation-age p50/p95 were 110.134/112.136 ms and 110.434/112.561 ms, respectively. All reported measurements exceeded their clock resolution. The peak sampled controller working set was 8.43 MiB, excluding the server, plugin, and other processes. The fixture made zero model calls.

All three eligible baseline probes reached CmdStart while the actor-side attack timer still had 730 ms remaining. None reached PrimaryAttack. All three eligible candidate probes reached PrimaryAttack and produced one matching clip decrement and playback event. One was a held-out moving variation. Both policies rejected every friendly and occluded probe before issuing attack input. No damage events or target health loss were observed. Neutral ticks add deployment time, so moving targets were farther from their starting positions in candidate runs. The result establishes discharge behavior on this fixture, with no evidence of improved accuracy or visual target recognition.

The accepted cancellation probe produced zero attack requests and verified the engine state after the neutral cleanup command. Nine corroborated observations from this suite were saved in the bounded SQLite fixture table. Prior iterations totaled 30 attempts: two setup timeouts from an incorrect gamedata class, two completed stationary pilots, one 12-case suite and a stop that arrived before the intended barrier, and one 12-case suite with a confirmed stop before the adapter stop latch was added. Those iterations remain outside the final-suite statistics.

Separate regression runs confirmed a plant, kill, and win on the original saved route in de_reflex_lab, and a plant on Dust II Plant Drill. A fresh Codex CLI session called get_combat_run for a stationary baseline run and correctly diagnosed the active 730 ms player timer and zero discharges. MCP comparison agreed with the final stationary pair.

## Dedicated teammate lobby smoke

On the configured Windows Dust II lab, the LAN broadcast query returned the lobby hostname. A real local client joined the dedicated server. The probe selected Hold, Follow and visible boxes through the H menu handler, changed team, and confirmed the bot's team rifle in its inventory. With the game in the foreground, the preview collected 10 measured frames after eight warm-up frames. Processing p50/p95 was 26.72/34.17 ms, delivered rate was 15.88 FPS, and the preview host peaked at 143.12 MiB. An earlier foreground-gated attempt collected zero frames. The server observed the preview's outline subscription. Track counts include HUD cues and are unsuitable for estimating player detection recall. This check did not measure match strength, audibility, or doorway success. Reproduce with the lobby launcher's `-UiSmoke` and `-ProbeVision` switches.

## Spawn view and offline pixel observer

The previous held-out moving AK fixture recorded one discharge and no damage. In two new runs of the same moving variant, the fake client consumed its outstanding spawn view before its first view command. Both fresh dedicated-server logs recorded a single AK attack for 140 damage and a kill. The first run still counted zero CSX damage events despite target health changing from 100 to -40. The second run used the post-damage game hook inside the owned shot and recorded one damage event and 100 HP lost. Its run ID is `1ffd267522d84519b53b75f872806a8b`. Server identity and line of sight supplied the target. These narrow runs do not estimate match win rate or visual target recognition.

On two existing annotated 480-by-360 frames, the first Ollama configuration timed out twice at 45 seconds. With a bounded context, smaller batch and longer offline deadline, local Qwen3-VL 2B returned unknown for active play (135.40 s including cold start) and console for the console image (13.83 s). Result: one of two scene labels correct, one missed match, zero false match labels. Person recall on the single annotated player was 0 with the inferred gate. The earlier human-gated run detected that player at score 0.826. This dataset is a diagnostic pair; collecting independently labeled recordings across maps and scenes is required before using predictions for live decisions.

### Reference laptop results

Runtime f013ada, release SHA-256 627AA5050AC6277DB2B135AFC4E9DA38EF2299E4A6178DB1E9574A5CDC43BE86.
Windows 11, Ryzen 5 4600H, 8 GB RAM, CPU only. All 72 measured tasks verified with zero model calls.

| Four-action workflow, 30 runs per mode | Disposable | Session |
| --- | ---: | ---: |
| Total p50 / p95 / p99 (ms) | 1090.35 / 1273.53 / 1354.30 | 877.42 / 1207.47 / 1301.38 |
| Flow / fixture readiness p50 (ms) | 511 / 466.79 | 298 / 467.38 |
| Action / discovery p50 (ms) | 127.24 / 61.50 | 70.42 / 55.17 |
| Spawn to entry / COM / UIA init per new worker p50 (ms) | 32.23 / 1.17 / 7.94 | 33.68 / 1.26 / 8.21 |
| Root / worker CPU per run p50 (ms) | 62.50 / 187.50 | 46.88 / 78.13 |
| Maximum sampled root / worker / concurrent private memory (MiB) | 1.49 / 2.86 / 4.25 | 1.52 / 2.95 / 4.40 |
| Workers created | 120 | 30 |

At n=30 nearest-rank p99 equals the maximum. For 1, 20 and 100 actions there were two measured runs per mode. Disposable/session total p50 values were 662/666, 2609/1361 and 10653/4733 ms respectively. At n=2 the reported median is the smaller observation. The longer fixtures repeatedly read Output after one Apply. The single-action case showed no latency gain.

Single in-flight fault probes, disposable/session time to termination in ms: cancellation 45.4/43.1, worker crash 28.6/30.6, timeout 11422.9/11415.9, lost window 30.0/25.4. Each stopped after one mutation attempt. Both fresh recovery runs verified. Queue and background disk readback, Studio smoke and 124 Rust tests passed locally. Remote CI status is separate.

Use `tools/Measure-NativeSession.ps1 -AllowVisibleUI -Quick` for a short functional comparison. Reserve the full matrix for changes to execution policy or published performance comparisons. Integrate instrumentation first, then the opt-in fixture session, then Diagnostics. Evaluate a second workflow with independent disk readback before changing defaults.

## 0.8.3 saved-text transfer on Windows

The task opens a new, nonactivating WinForms fixture, fills its editor, saves
once and independently reopens the output. Five sequential UIA requests serve
one save. The old and new disposable paths use the same fixture, goal, expected
bytes and exclusive-create rule. The new session path changes the worker
lifetime. Every measured run must publish its own verified queue receipt.
Candidate timing and skill evidence must match that receipt's run ID.

Windows 11 Pro build 26300, Ryzen 5 4600H, 7.37 GiB OS-visible RAM. CPU only,
zero model calls. Seven measured runs per mode, one excluded warmup per mode;
starting order rotates each iteration. Every run uses a fresh runtime process
and fixture. End-to-end time includes fixture launch and process exit. A Windows
Job Object attached immediately after launch measures CPU, total associated
processes and peak concurrent job commit, including the PowerShell fixture.

| Mode | Verified | End-to-end p50 / p95 / p99 / max (ms) | Tree CPU p50 (ms) | Peak tree commit (MiB) | Processes per tree |
| --- | ---: | --- | ---: | ---: | ---: |
| 0.8.2 disposable | 7/7 | 1249 / 1395 / 1395 / 1395 | 1250 | 81.00 | 16 |
| 0.8.3 disposable | 7/7 | 1281 / 1485 / 1485 / 1485 | 1344 | 80.96 | 16 |
| 0.8.3 opt-in session | 7/7 | 981 / 1156 / 1156 / 1156 | 1063 | 81.36 | 8 |

The new disposable median increased by 32 ms. The opt-in session median was
268 ms lower than the original disposable median. Each mode recorded 35 UIA
requests across seven runs. The two candidate modes recorded 35 and 7 worker
starts respectively. A job process count includes other Windows children.
With nearest-rank percentiles at n=7, both p95 and p99 are the slowest run.
These are descriptive results from one machine. Keep the default disposable.

| Candidate phase | Disposable | Session |
| --- | ---: | ---: |
| Goal planning p50 (µs) | 29 | 29 |
| Action p50 / p95 (ms) | 112.96 / 142.40 | 42.29 / 120.22 |
| Worker creation p50, starts only (ms) | 6.79 | 6.62 |
| COM / UIA initialization p50, starts only (ms) | 1.29 / 7.92 | 1.51 / 7.98 |
| Final independent readback p50 (µs) | 693 | 655 |
| Maximum sampled runtime + worker private memory (MiB) | 3.95 | 4.01 |

Per-action observations overlap their nested phases. CPU time is cumulative user
and kernel time across the associated processes. Job commit and sampled private
memory have different scopes. The baseline did not emit per-action phase data
for this Goal. Single-call binding medians were below clock resolution. An
isolated optimized release microbenchmark (31 batches of 4,096 lookups, one
excluded warmup, no file or UI access) returned 3.69 ns per bind at p50/p95/p99
and maximum, rounded to two decimals. This includes registry lookup, capability
negotiation and binding together. It does not predict workflow latency.

Release SHA-256 values:

- Baseline from the native-session checkout: `627AA5050AC6277DB2B135AFC4E9DA38EF2299E4A6178DB1E9574A5CDC43BE86`.
- Candidate runtime `f81b79c`: `8A004ECCEAB04364EDB4A1329B42532B2249931ACB61D9A4B2BE157E820150B7`.
- Shared fixture: `97AA5AF18633EB5A4672737E300E917001AD02D3A19285603C869E42D488E156`.

Build both revisions independently. From the feature checkout, pass the location
of the built baseline. Correlated rows stay in gitignored local data.

```powershell
.\tools\Measure-SkillTransfer.ps1 -BaselineRoot ..\native-execution-sessions -Runs 7
cargo test --locked --release measure_binding -- --ignored --nocapture
```

### Transfer and negative evidence

* WinForms saved and verified through both worker modes. The queue test also
  sampled the foreground window and confirmed it stayed unchanged.
* The final Notepad acceptance verified 2/2 fresh saves (plain and held-out
  Unicode), with an external read of each file and zero model calls. Elapsed
  times were 1,097 and 1,752 ms in sorted order. This is a functional pair.
  A development run passed 1/2: on the first attempt the editor failed the
  initial-empty check before editing. The supervisor now briefly re-observes
  the owned editor before rejecting it. The original UIA state was not captured.
* Fault injection against the inherited session supervisor measured cancellation
  at 52.8 ms, crash at 37.3 ms, lost target at 34.1 ms and timeout at 11,394.5
  ms. Each is one probe. The fresh recovery run passed in 847.8 ms. These are
  supervisor measurements, not cancellation percentiles for Notepad.
* Contract tests reject absent capabilities, incompatible versions, a background
  Notepad request, mismatching or oversized outputs and missing readback. MCP
  integration rejects foreign evidence and unsupported verifier versions.
  Studio compilation, UI smoke, queue recovery, skill-memory checks and the
  release Rust suite passed locally (127 tests and one separately run microbenchmark).
  A separate queue test retained two distinct Notepad receipts tied to their
  original runs and independently reported zero model calls.

### Supervised editor receipt acceptance

On Windows 11, the queue started two foreground Notepad workers. The test
reopened both files after the terminal entries appeared and matched the expected
Unicode text in 2/2. Both receipts referenced distinct supervisor-assigned
runs. The second worker reused the saved method. Both reported zero model calls.
The standalone Unicode check also passed once with external readback.

Earlier queued attempts stopped before typing when the worker could not
activate the owned document. The tray now asks Windows to pass its activation
permission to the specific foreground worker. The worker still requires a
unique visible target in the foreground. A separate background test detected a
foreground change during one attempt; the source of that change was not
identified. These are functional checks. The timing comparison above measures
the earlier A/B checkpoint.

The final background pass verified WinForms disk output with the original
foreground window at each poll. Eleven synthetic queue cases exercised the
commit decision. Only the matching receipt from a successful worker received
verified status. The cases included cancellation after exit, incompatible or
foreign evidence, malformed fields and worker failure after staging a receipt.
The last valid job completed after all the rejected cases.

```powershell
.\tasks\Test-Queue.ps1
.\tasks\Test-Queue.ps1 -AllowInput
.\tasks\Test-Queue.ps1 -UiaFixture
```

### Text composition acceptance

With the session worker selected, one interactive Windows pass per mode took 949 ms (foreground WinForms), 997 ms (background WinForms) and 2236 ms (Notepad), measured from the harness including external file checks. All three originals and UTF-8 derived copies matched. The background foreground-window probe sampled every 30 ms. These single observations do not establish tail latency, resource use or a speedup. An initial PowerShell 5.1 harness failed to obtain the background exit code through Start-Process; the corrected harness owns the Process instance. See tasks/Test-TextComposition.ps1.

Sequential reuse functional cohort (one Windows run per plan and binding, session worker selected). Four steps: foreground WinForms 927 ms, background WinForms 988 ms, Notepad 2280 ms. Six steps: 1352, 1171 and 2749 ms respectively. All six included independent source and output checks; the background probe sampled foreground ownership. The longer plan performs additional work. These are individual observations, not a paired manual baseline or latency percentiles.

## Phase C file publication comparison

On the local Windows development machine, two warmup pairs and 30 measured pairs used alternating order, new run IDs, separate NTFS fixture folders, identical source and suffix, exclusive publication and independent readback. The timed interval starts with an existing source and ends after final verification. All 60 measured outputs passed an external read. Manual sequence p50/p95/max was 12.375/16.891/48.190 ms; registry composition was 12.556/26.306/75.444 ms. Nearest-rank p99 equals the maximum at this sample size. This series showed a higher candidate tail; it cannot isolate its cause. Editor startup, queue, receipts and process resources are outside this measurement. Both paths use zero model calls.

Reproduce with cargo test --release --locked paired_copy_timing -- --ignored --nocapture. Run cargo test --locked abrupt_composition_exit for abrupt termination at seven publication lifecycle boundaries plus a fresh recovery. The latter uses a synthetic editor source and checks actual files from a parent process.

## Phase C interactive queue comparison

Windows 11 Pro build 26300 on a Ryzen 5 4600H with 7.37 GiB visible RAM. Five paired runs alternated execution order in one interactive session. Both modes used the same release executable and native background WinForms six-step graph. The queue arm included task submission, exact approval, worker startup, queue receipt commitment and external file readback. The direct arm started the CLI and independently checked the receipt and both published files. All ten attempts verified both derived files. No model calls were needed.

- Direct CLI latency p50/p95 was 1275.5/1516.8 ms. Sampled worker-tree CPU p50 was 1046.9 ms. Highest concurrent worker-tree private memory sample was 79.7 MiB.
- Queue latency p50/p95 was 1708.4/1832.8 ms. Sampled worker-tree CPU p50 was 1546.9 ms. Highest concurrent worker-tree private memory sample was 139.6 MiB.
- Harness CPU p50 was 343.8 ms for direct and 453.1 ms for queue. PowerShell and the Windows process sampler add overhead. CPU represents observed process handles and can miss very short-lived descendants. Private memory is the peak of concurrent samples, not the sum of per-process peaks. At five runs per arm nearest-rank p95 is the maximum. These results characterize the queue path, not a speedup claim or the independently orchestrated baseline.

Reproduce with Windows PowerShell 5.1 using tasks/Test-Handoff.ps1 -CompareComposition -Sessions 5. Release executable SHA-256 was 9e34e479c2538affd75f99b5e79e0793f2ce7a3b75b2e9e6ca5b5a078d3bcdec.

## Phase C manual orchestration versus graph

Thirty alternating pairs ran on the Ryzen 5 4600H Windows 11 workstation with 7.37 GiB visible RAM. Both arms used one release executable, the same background WinForms editor, identical input and suffixes, and identical cancellation, authority, durable staging, exclusive rename and independent readback. The benchmark-only manual branch uses explicit source consumption followed by two fixed create-and-verify sequences. It bypasses graph interpretation. The measured interval includes process startup, editor work, source verification, two publications, receipt and external file checks. It uses no model calls.

- Manual: 30/30 verified. Latency p50/p95/max 1344.6/1603.2/1924.8 ms. Observed worker CPU p50 1140.6 ms, harness CPU p50 406.3 ms. Concurrent sample private memory p50/max 78.6/116.7 MiB.
- Graph: 30/30 verified. Latency p50/p95/max 1352.1/1558.2/1583.7 ms. Observed worker CPU p50 1062.5 ms, harness CPU p50 390.6 ms. Concurrent sample private memory p50/max 78.9/80.2 MiB.
- The median wall-clock difference was 7.5 ms. The measurements do not establish a general speed advantage. The largest manual memory observation was an outlier. Worker measurements use sampled process-tree membership and can miss short-lived processes. Harness CPU includes the CIM sampler. At 30 runs, nearest-rank p99 is the maximum. The earlier direct-versus-queue comparison remains a separate experiment.

Build with cargo build --release --locked --features composition-benchmark. Reproduce using Windows PowerShell 5.1 and tasks/Test-Handoff.ps1 -CompareManualComposition -Sessions 30 -MetricsFile with a fresh local output path. The test requires the arm marker in each receipt and verifies both outputs externally. Executable SHA-256 was 637525db623062d8130b3052ef2d6af1178bd3b07fd3033e0d0fc59c9c8e57f7.

## Phase D discovery on Windows

The owned Document Preview fixture qualified 5/5 candidates on the Ryzen 5 4600H Windows 11 workstation. Seven invalid inputs were rejected before fixture startup, including ambiguous application declarations, unknown application, capability mismatch, missing or unknown verifier, and oversized input. Interactive runs independently asserted the candidate envelope, checked foreground at 15 ms waits, and left no persistent queue or registry state in the isolated fixture root.

From process start through exit, first run latency was 1124 ms. The next four runs had nearest-rank warm p50/max of 777/781 ms. Across all five runs, CLI CPU p50/max was 46.875/62.5 ms and UIA worker CPU p50/max was 31.25/62.5 ms. Peak sampled CLI private memory was 1.41 MiB, and the maximum concurrent CLI plus UIA sample was 3.88 MiB. PowerShell fixture startup is included in wall time. The separate fixture process is outside the reported CPU and memory measurements. Every response was 741 bytes including the line ending. No model calls were made.

Reproduce with cargo build --release --locked and tasks/Test-SkillDiscovery.ps1 -Interactive -Runs 5. Run the same script without -Interactive for the unattended negative suite. The measured release executable SHA-256 was 4e93a23bd7019939953ac081ea43ea31102e06a0a8c493a132e1fb121442f047. Five runs qualify the fixture, with no general latency or resource claims about other applications.
