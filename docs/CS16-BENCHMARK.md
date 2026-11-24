# Counter-Strike 1.6 offline benchmark

Use this benchmark on a GoldSrc Counter-Strike 1.6 local practice match. It scores the game's server log for one numeric userid and produces JSON suitable for comparing runs. Log names, Steam IDs, chat and local paths stay in the input file. Keep the raw log and demo local.

## Capture and score

1. Start a private local match. In the server or listen-server console run `log on`. For a fresh run use `sv_restart 1`. Record the numeric userid reported by the game's `status` command. Userids can change on reconnect.
2. Optionally record the controller's first-person demo with `record practice_trial`. Finish it with `stop`. Finish the log with `log off` so the engine flushes its buffers.
3. Run the exact same map, scenario, spawn policy, target site and controller settings when comparing builds. Pass the complete log capture for each trial.

~~~powershell
cargo build --locked --release
.\target\release\reflexcore.exe cs16 benchmark <server.log> --player <userid>
.\target\release\reflexcore.exe cs16 benchmark <server.log> --player <userid> --require-bot-win
~~~

Plant success requires C4 evidence and a matching player plant event in the same round. The report distinguishes the time from confirmed spawn with C4 from the time after `Round_Start`, which marks the end of freeze time. The engine log has one-second resolution. A round or capture ending without the required evidence is reported separately. A positive easy-bot result also requires a CT bot kill by the actor, an explicit difficulty 0 setting in the log, a Terrorist win and a completed round.

The reader was tested with a real local `de_dust2` capture. It identified the only measured round, its C4 spawn and freeze end, and reported zero verified plants after the capture closed 83 seconds later. This is a baseline with incomplete objective evidence. It supplies no successful completion time.

## Isolated spawn-to-plant acceptance

The original `de_reflex_lab` scenario ran on a loopback-only dedicated server with Valve's Steam legacy GameDLL, ReHLDS 3.15.0.896, Metamod 1.21.1-am and AMX Mod X 1.10.0.5488. Each trial started a fresh server with one ReflexCore Terrorist and one stationary CT. The server used standard movement, C4 issuance and planting. The adapter drove its fake clients through the GameDLL's team and class lifecycle before restarting the round. It acknowledges the one-shot spawn view update for its own fake client so the engine can accept subsequent yaw input.

The previous adapter stalled at maximum speed 1.00 with the actor still in team selection. In the revised adapter, all three trials reached the plant site and planted. Both the actor-scoped CSX callback and the GameDLL log recorded each plant. The independent benchmark scored the fresh console capture from `-condebug` for the same actor and recorded 13 seconds from spawn and freeze end in each trial. Timings use the stock one-second event clock.

Across the three successful runs, controller navigation measured 8,546–8,580 ms and planting measured 4,154–4,162 ms. Total wall time measured 14,764–14,796 ms, including setup and the final stop. Median total time was 14,769 ms. Each trial used 78 movement commands and 36 planting commands.

One cancellation test created the private cancellation marker after five movement commands. The controller exited with a cancelled receipt 208 ms later, with the stop acknowledged, its exclusive lock released and zero plant commands. Pass `--cancel-file <unique-private-file>` after `--allow-offline` to request this behavior. Create the marker during the run and manage it from the caller that owns it.

A subsequent Dust II trial generated 28 collision-checked waypoints from a measured C4 spawn. The next restart selected a spawn 96 units away, outside the route's initial 24-unit radius. The controller stopped at the anchor check with zero movement commands. Dust II needs route selection after observing the actual spawn. Easy-bot scoring remains a separate test.

The tested adapter source SHA-256 is `c28fdb0f9dccb8bafc6a0b93607e6a46bcf0b91784783f1f5a73f3ac0a345459`. The controller source SHA-256 is `445e776eead62d71d5d02b6b1207979b9d3f3e08b64b4a881bce1ebeb9bd2bf0`.

## Read-only telemetry

~~~powershell
.\target\release\reflexcore.exe cs16 probe --port 27015 --pid <game-pid>
.\target\release\reflexcore.exe cs16 demo <first-person.dem>
.\target\release\reflexcore.exe cs16 route-draft <first-person.dem> A <start-seconds> <end-seconds>
.\target\release\reflexcore.exe cs16 route-check <route.json> <first-person.dem>
~~~

The probe sends one bounded IPv4 loopback query to a CS listen server and can check the local listener owner. The demo reader supports GoldSrc demo protocol 5. A closed demo can generate a waypoint draft from a selected interval. Review the endpoints and corner spacing before using it. Route-check evaluates the first living pose and emits a bounded steering decision. Neither path is evidence of execution. Source formats and event timing are documented by [Valve's ref_params header](https://github.com/ValveSoftware/halflife/blob/master/common/ref_params.h), [Talent's parser documentation](https://github.com/cgdangelo/talent/blob/main/libraries/parser-goldsrc/docs/demo-structure.md), [ReGameDLL's round start](https://github.com/rehlds/ReGameDLL_CS/blob/master/regamedll/dlls/multiplay_gamerules.cpp) and [its C4 event](https://github.com/rehlds/ReGameDLL_CS/blob/master/regamedll/dlls/wpn_shared/wpn_c4.cpp).

## Static route planning on the local map

The BSP planner reads a locally installed GoldSrc v30 map and a measured Terrorist spawn. It checks the standing player hull, ordinary stairs, static obstructions, the selected bomb target volume and every emitted segment. Pass a map, a local spawn and an explicit brush model number. Inspect `--help` for all options.

~~~powershell
py examples/plan_cs16_bsp_route.py <de_dust2.bsp> --start -736 -704 164.03125 --site A --target-model 42
~~~

The official Dust II BSP yielded a 28-waypoint route to its eastern plant volume and a 24-waypoint route to its western volume from the measured spawn. A second Terrorist spawn also produced a collision-checked east route. These are planning measurements. Verify movement, plant and match outcome separately in the engine.
