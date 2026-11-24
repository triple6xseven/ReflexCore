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

The Studio offline match requires `--require-plant-kill-win`. That flag requires a plant, the selected actor’s kill of a CT bot and a Terrorist win in the same completed round. It accepts the local AMX fixture and does not assign it a stock difficulty.

The reader was tested with a real local `de_dust2` capture. It identified the only measured round, its C4 spawn and freeze end, and reported zero verified plants after the capture closed 83 seconds later. This is a baseline with incomplete objective evidence. It supplies no successful completion time.

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

The isolated Plant Drill was verified on the original de_reflex_lab fixture. On Dust II, a live C4 spawn led to a valid static route. The trial restarted the round and got a different spawn, 96 map units away. The controller rejected the spawn anchor before dispatching movement. The next milestone is choosing the route from the post-restart spawn. See [measured fixture results](BENCHMARKS.md).

## Automatic offline plant routes

In Studio, open **Shared Control / Open Offline Plant Drill** and select a demolition map. The list comes from the isolated dedicated server's `cstrike/maps` directory. **Saved route** remains available for regression runs. Python 3 must be accessible through the Windows `py.exe` launcher.

The local Rust adapter waits for a live Terrorist carrying C4, reads the current spawn from GoldSrc, then calls the existing BSP walker. Automatic search uses all supported brush bombsite volumes and a standing hull. It checks every output segment. One bounded replan can run from the latest actor position after confirmed lack of movement. It searches a finer grid and switches brush group when another group exists. It aborts if the map, actor or sequence changes during planning. C4 placement requires fresh server-side zone and plant evidence. Coordinates and display labels for map sites are not imported from the saved laboratory route.

The CLI equivalent, from the project root with the same isolated practice plugin enabled:

```powershell
.	argeteleaseeflexcore.exe cs16 practice <mailbox> auto --allow-offline --stationary-opponent
```

Automatic mode currently covers the plant objective on supported GoldSrc BSP v30 demolition maps. Ladders, jumps, crouching passages, moving geometry, point-only bombsites, hostage/assassination objectives and full adversarial matches across arbitrary maps require additional adapters or movement skills. The existing `de_reflex_lab` match remains the verified win baseline. Separate a successful route plan, a verified plant and a verified match win in all measurements.
