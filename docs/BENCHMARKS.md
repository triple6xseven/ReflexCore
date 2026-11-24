# Windows acceptance measurements

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
