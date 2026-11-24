# ReflexVision v0.1

ReflexVision provides a live preview for windowed Counter-Strike 1.6 and publishes small typed observations to the existing Rust CS16 command. The separately supervised Plant Drill controls a player in an isolated GoldSrc server.

## Use Studio

Open **Shared Control**. **Start ReflexVision** opens a preview with purple tracks next to the local game. Labels identify tracked color and HUD regions. Bring the game into the foreground to resume capture. Leave room beside or below the window for the preview. **Stop Capture** or the PowerShell stop action closes the preview. **Ctrl+Alt+F10** triggers [emergency stop](EMERGENCY-STOP.md). The start script checks that the selected game process owns a loopback-accessible CS 1.6 listen server with one human player.

**Start Offline Plant Drill** opens a second panel with the real position of the ReflexCore player, the route and the controller's progress. The fixture launches a dedicated loopback server with no human clients. The player moves through ordinary game ticks and holds Attack with C4 equipped inside an engine-confirmed plant zone. The Rust result requires the owned actor's plant event. The panel's Stop button cancels that run. The movement display is a route view, while ReflexVision displays video from a windowed client.

### Replayable offline match

**Play Offline Match** starts an owned loopback instance of the original de_reflex_lab. ReflexCore navigates the route, plants C4, and uses normal Glock input against a local AMX fixture defender. The defender patrols and attempts to retake the site after the plant. No stock difficulty is implied. The panel requires an independent GoldSrc log containing the selected actor's plant, CT bot kill and same-round Terrorist win.

The match starts an HLTV recorder on the next port after the practice server. **Copy spectate command** copies the loopback-only console command for live viewing. **Recordings** opens the saved HLTV demo and its redacted result in the local replay directory. To replay from a separate client, place `de_reflex_lab.bsp` in `cstrike/maps`, place the recorded `.dem` in `cstrike` and run `viewdemo <recording-name>` in the game console. A recording is saved only after the game's HLTV recorder finalizes the directory.

Build and enable the current practice plugin in the isolated lab. The match requires the Hamsandwich AMX Mod X module and the lab's `hltv.exe`. The existing Plant Drill uses the same private server settings and still supports the stationary fixture.

## Capture and observations

The direct path scales the desktop client rectangle into a reusable top-down DIB, ready for the CPU detector. The comparison path captures full resolution and downsamples on the CPU. The WinForms preview uses the same scaled memory, draws tracked boxes and adjusts its cadence when load rises or the frame is empty. The process needs no model, image encoding, temporary video or Python service.

The classical detector uses sparse red connected components in the scene and gold-pixel occupancy in the lower HUD ROIs. It emits candidate visual cues and HUD regions. The scores are heuristics. Red cues can be scenery. Gold HUD colors and layouts can change between themes and games. The detector does not identify opponents, read the numbers, classify plant sites or prove a plant. The tracker associates same-class boxes by overlap, confirms on two consecutive observations and retains an ID for brief occlusion up to 350 ms. Missing detections are omitted immediately.

The relay replaces data/bridge/reflexvision.json with the latest observation at up to eight writes per second. Each live frame has a schema, monotonic per-process sequence, capture timestamp, dimensions and a bounded list of track IDs, classes, scores and pixel boxes. Rust rejects non-live, oversized, invalid and expired snapshots. CS16 can read a fresh observation with `reflexcore cs16 vision`. No pixels, prompts, player names or window titles enter that protocol. Existing movement and verification use independent engine evidence.

### Player rectangles

Live capture currently shows color and HUD regions. Player inference is suspended while the client scene is unverified. The Rust relay already excludes player tracks.

Place the official YOLOX-Tiny ONNX export at `%LOCALAPPDATA%/ReflexCore/vision/yolox_tiny.onnx`. Install the worker dependency with `py -3 -m pip install --target "%LOCALAPPDATA%/ReflexCore/vision/python" opencv-python-headless` from Command Prompt, or use the equivalent expanded path in PowerShell. The worker validates the release file SHA-256. The worker remains available for development. Its input masks the radar and lower HUD while preserving frame coordinates. [YOLOX official ONNX exports](https://github.com/Megvii-BaseDetection/YOLOX/tree/main/demo/ONNXRuntime)

## Repeat a measurement

~~~powershell
powershell.exe -NoProfile -STA -File .\tools\ReflexCore-ReflexVision.ps1 -Action SelfTest
powershell.exe -NoProfile -STA -File .\tools\ReflexCore-ReflexVision.ps1 -Action BenchmarkFixture -Capture Direct
powershell.exe -NoProfile -STA -File .\tools\ReflexCore-ReflexVision.ps1 -Action BenchmarkGame -Capture CpuScale -Samples 120
powershell.exe -NoProfile -File .\tools\ReflexCore-ReflexVision.ps1 -Action Stop
~~~

Run foreground benchmarks sequentially. The game test needs an already running offline listen match. The fixture paints a moving red component and a gold HUD cue. Results include FPS, p50/p95 capture-to-paint time, average CPU as a percentage of one logical core and process working set. See [Windows measurements](BENCHMARKS.md).

## Set up a portable Plant Drill lab

Use an isolated Windows Valve HLDS legacy install. The tested setup uses ReHLDS 3.15.0.896, Metamod 1.21.1-am and AMX Mod X 1.10.0.5488 with cstrike, fakemeta and csx. Compile games/cs16-practice/reflexcore_practice.sma with amxxpc and enable the plugin in the isolated server only. Generate de_reflex_lab.map, its original textures and its route using examples/build_cs16_lab_map.py. Compile the map with GoldSrc-compatible tools and copy the BSP into the isolated cstrike/maps folder. Configure that server's rc-practice.cfg with sv_lan 1, rc_practice_enabled 1, sv_cheats 0, mp_freezetime 0, mp_autoteambalance 0, mp_limitteams 0 and log on.

Create the private data/settings/cs16-practice.json. Set schema to reflexcore.cs16.practice.launcher.v1, runner_exe to the project-local release binary, mailbox to the isolated server's cstrike/addons/amxmodx/data/reflexcore directory and route to the generated waypoint JSON. Set stationary_opponent to true. Automatic routing requires the current compiled practice plugin and a fresh engine-confirmed round on the owned loopback server. Set server_exe to the isolated hlds.exe and port to its loopback port to let the panel run and close that server. Dependencies, logs, route outputs and configuration stay local.

For automatic routing, choose an installed demolition map in the Plant Drill panel and press Start. The runner binds the observed spawn to a new engine round generation. It keeps short hops where a shortcut lacks lateral standing clearance. After a measured stall, recovery uses a fresh actor position and excludes the blocked direction for the first hop. Up to two recovery attempts are allowed. A stale pose, discontinuity or missing round evidence stops the drill. An engine-confirmed plant zone can complete automatic navigation before the final planned waypoint if the pose is still valid. The panel distinguishes reaching a zone from a verified plant. Enable Record replay for the automatic drill to save its HLTV demo under Recordings when the owned server has a recorder. The drill still runs if the recorder is unavailable. Full rounds with an active defender are assessed separately in the lab match preset.

Run `tasks/Test-CS16AutoRoute.ps1 -Server <owned-loopback-hlds.exe> -Map <de_map>` to reproduce the automatic drill and independently verify the actor's plant from the fresh game log. The script expects a compiled project release and the current practice plugin installed on the isolated server.

The practice fixture runs without any global keyboard or mouse input. For an independently scored run, pass the new segment of the engine log to `reflexcore cs16 benchmark <server.log> --player <userid>`.

## Local experiment coach

Add `-Coach` to `tasks/Test-CS16AutoRoute.ps1` to review an independently verified run after the owned server has closed. You can also call `tools/ReflexCore-CS16Coach.ps1 -BenchmarkReport <Rust benchmark JSON>` directly. The coach reads the existing SQLite pulse statistics through `reflexcore learning registry`. An optional `-VisionReport` from the scorer below is a separate dataset. Pass `-VisionScope synthetic` for test labels. The automatic drill accepts a measured vision report via `-CoachVisionReport`.

Ollama receives aggregate counts only. It selects one allowed investigation, such as measuring actual shot outcomes, and has no action channel. Rust and the engine remain the authority for game evidence. Missing, malformed or unavailable model answers use the deterministic recommendation. The current version assumes the 2B Qwen model installed locally, with an optional `-Model` override on the coach script. The coach does not load a different model while another is resident.

## Offline detector scoring

Run `node tools/score-reflexvision.mjs <private-frame-records.jsonl>`. Each line contains a unique integer `frame`, a `scene` of `menu`, `console`, `loading`, `match`, `dead` or `spectator`, and arrays `truth` and `detections`. Match frames require an integer server `tick`. A truth box is `[x,y,width,height]` in frame pixels. A detection has `box` and a `score` between 0 and 1. Use empty truth for non-match scenes and empty corridors. The scorer uses one-to-one matches at IoU 0.50 and reports precision, recall and negative frames with detections.

Prepare synchronized server ticks, frame numbers and visible ground-truth boxes before scoring. Server positions alone cannot label visible boxes without camera projection and occlusion checks. Keep datasets and recordings outside Git.
