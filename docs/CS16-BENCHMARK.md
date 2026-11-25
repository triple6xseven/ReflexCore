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

## Adversarial Dust II round

The owned Dust II match uses a fresh BSP route, an AK-47 fixture and one moving CT. The defender can engage during navigation, after contact and after the plant. The original saved-route laboratory remains available in the same Studio map selector. The experimental match uses native fake-client game commands on the dedicated loopback server and does not send desktop input.

Build the practice plugin with AMX Mod X 1.10 and install it in an isolated server with CStrike, CSX, FakeMeta, Ham Sandwich and Fun. Run the project release executable and matching plugin together. In Studio, open **Shared Control / Play Offline Match**, select Dust II and use **Run match again** or the existing automatic launch. The panel can open Recordings and issue a loopback spectator command. CLI fixture examples from the project root:

~~~powershell
cargo test --locked
cargo build --release --locked
.\tasks\Test-CS16AutoRoute.ps1 -Server <owned-hlds.exe> -Map de_dust2 -Match -EvidenceDirectory <private-output> -Record
.\tasks\Test-CS16AutoRoute.ps1 -Server <owned-hlds.exe> -Map de_dust2 -Match -EvidenceDirectory <private-output> -CancelInRound
.\tasks\Test-CS16AutoRoute.ps1 -Server <owned-hlds.exe> -Map de_reflex_lab -Match -SavedRoute <lab-route.json> -EvidenceDirectory <private-output>
~~~

The versioned companion snapshot binds the simulation tick, command sequence, actor and round generation. The plugin checks the generation on adversarial commands that move or equip the actor. Contact, accepted attack requests, clip decrements and AK-47 damage events have separate counters. The independent GoldSrc log establishes completion, plant, winner and combat kill evidence. A completed loss or a win without planting can be represented. Observation percentiles cover synchronized mailbox reads and retries. Decision percentiles cover the combat branch only, excluding mailbox commands and engine acknowledgement. Working set is sampled for the Rust worker by the harness. Keep resulting JSON, logs and demos outside the repository.


Use **Watch replay** in the practice window to choose a finalized GoldSrc demo. Select the Counter-Strike 1.6 client on first use in that window. Studio stages a uniquely named copy in the client's cstrike folder and opens the client with the replay command. Close a running game client before launching playback if it refuses a second instance.

In Studio, choose **Shared Control > Browse match replays**. The list scans the local recording folder, selects the newest completed file, and plays any selected row with a double-click or Enter. Refresh to include newly saved files. Older recordings show their map and file modification time, with the build version marked Unknown when it was not recorded. New filenames include the available source build version, UTC run start, map, and recording ID.

Practice plugin 1.2 checks that the controlled actor and visible target are on opposing teams before generating target angles. The adapter rechecks identity, life state, weapon and line of sight at the attack command. In the adversarial fixture, a clip decrement produces fired; an accepted request without a decrement produces no_shot. The legacy saved-route fixture keeps its original command behavior. This is server-provided target evidence. The defender still uses direct movement and may get blocked by map geometry.

Use `-PublishMcpSummary` with an automatic offline match to expose its redacted outcome through the local MCP server. The published record carries the run ID and separate counts for contact, shot requests, confirmed discharges, and damage events. Round verdict fields are null until the fresh log confirms a completed round. The `--require-completed-round` scorer mode accepts a completed loss without a plant. Plant Drill and the original saved-route scorer retain the plant requirement.


## Offline combat fixture

The synthetic de_reflex_lab geometry provides a straight lane and a solid divider. The fixture positions two owned fake clients and equips an AK-47. Its success criterion is an observed attack outcome. It sends no plant commands. The base suite includes stationary, moving, friendly, occluded, heldout_moving and heldout_occluded scenarios. The held-out scenarios change distance or angle. The harness pins initial positions, but the engine RNG and scheduling are not controlled. The private suite header records hardware and SHA-256 for the server, GameDLL, BSP, controller and plugin.

The baseline reuses the release-plus-attack pair of engine commands after equipping. The candidate runs ordinary neutral player moves once per practice tick while waiting for the weapon to deploy. Both issue at most one attack probe. The friendly and occluded probes test rejection before any attack input reaches the engine. A separate cancellation trial waits for a run-specific ready marker, sends cancellation, exercises the dispatch guard and reads the engine state after the neutral cleanup command.

The one-action trace binds the mailbox sequence, round generation, scenario, and same-tick snapshot. It records actor-side and weapon-side timers, CmdStart attack callbacks, the Ham PrimaryAttack hook, AK-47 playback, clip readback, CSX damage and target health. Clip consumption and playback must agree to count a discharge. The target's health is a separate readback. The reported reaction timer measures request dispatch through mailbox acknowledgement. Observation age uses the engine tick on the sampled state and the engine tick at acceptance. Neither represents camera-frame or visual-perception latency.

Useful upstream references are the [AK-47 primary attack and playback implementation](https://github.com/rehlds/ReGameDLL_CS/blob/master/regamedll/dlls/wpn_shared/wpn_ak47.cpp), the [AMX Mod X Ham hook contract](https://github.com/alliedmodders/amxmodx/blob/master/plugins/include/ham_const.inc), and the [Fakemeta engine interface](https://github.com/alliedmodders/amxmodx/blob/master/plugins/include/fakemeta_const.inc). The installed AMXX gamedata locates the player timer in CBaseMonster. The measured Windows Lab confirms that a native attack command can reach CmdStart while the player timer still prevents PrimaryAttack. It also confirms that PrimaryAttack can produce clip consumption and playback without damaging the target.

~~~powershell
cargo build --release --locked
# Compile games/cs16-practice/reflexcore_practice.sma with the lab's AMX Mod X compiler.
.\tasks\Test-CS16CombatFixture.ps1 -Server <owned-hlds.exe> -Plugin <compiled-amxx> -EvidenceDirectory <empty-private-folder> -PublishMcpSummary -Remember
~~~

The harness temporarily loads the explicitly supplied plugin and restores the previous binary. Use a dedicated owned server folder. The fixture checks the exact loopback process and holds the Rust mailbox lock during execution. MCP exposes redacted read-only trial summaries through list_combat_runs and get_combat_run. compare_combat_runs accepts only completed baseline and candidate trials from the same suite and scenario. The plugin documents these tools for Codex after a session reload. None of the tools exposes combat actions.

-Remember records only corroborated discharge samples and correct friendly or occluded rejections in the existing SQLite database. The fixture uses a separate bounded table and honors Learning Off. Timeout, cancellation and no-discharge timer failures remain in benchmark data. No recorded sample activates a policy or trains weights.

For interactive play with a human and an independent bot on Dust II, use the [local team lobby](CS16-LOCAL-TEAM.md).
