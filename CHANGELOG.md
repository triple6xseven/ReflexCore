## Velvet Enchantress and directional hover

- Add Velvet Enchantress beside Lunar, with split pleated overskirt, butterfly ornaments and matching legwear variants. Hover now banks and balances arms and legs with flight velocity.

## Window edge crossed-leg animation

- Alternate the existing window sit with a supported knee-over-knee pose and eased leg lift when sitting motion is enabled.

## Cloud sitting poses and Studio caption

- Cycle through dangling legs, tucked knees and side sitting on the cloud. Rest the hands on the lap and raise the transition frame budget. Inset the custom caption when Studio is maximized.

## Alternating companion animations

- Alternate classic interactions with new head-pat, smile, drag, flight, impact, landing, climb, thinking and work gestures. Window and cloud seats independently alternate leg-swing accents.

## Companion window visibility

- Place companion window controls on the Character page. Fullscreen visibility follows the companion topmost switch.

## Diagnostics navigation contrast

- Replace native tab headers with themed section buttons and place the measurement note above the content.

## Diagnostics theme

- Theme Diagnostics tabs and chart from the Studio palette and fit the embedded dashboard footer to the available height.

## Studio layout and cloud flight

- Keep Agent status above the action buttons, widen the sidebar, and target at least 48 FPS while the cloud is travelling.

## Lunar wardrobe and desktop motion update

- Tailor the Lunar neckline, sleeves and side panels, add an opaque lavender liner and sculpt barefoot toes. The dark stocking variant has a higher scalloped hem.
- Align desktop walking with the work-area floor. Add cursor-aware Hover and short Free Roam cloud flights. Rework walking and cloud-summon arm movement. Blend out of window and cloud seats before leaving, with drag taking priority.
- Add Show over fullscreen apps in Studio. Preserve capture suspension and cap MSAA on enlarged overlays to limit rendering cost.

## Lunar Temptation

- Add a separate private Lunar VRM pair with layered ponytail locks, side strands, flared sleeves and a split overskirt. Simplify the Studio edition list and articulate walking and cloud gestures in rig space.

## Diagonal throws

- Fix a typed-array error that interrupted flight in Taskbar, Stationary and Follow Cursor modes. Preserve short mouse flicks at release, combine successive side and ceiling contacts into a corner rebound, and recognize side-to-floor corner landings.

## Companion touch and impact reactions

- Add face smiles, foot tickles, directional drag lean and speed-sensitive contact rings. Free Roam approaches a distant cursor during its existing walks. The approved seated baseline is tagged companion-seated-classic-1.

## Companion seat visibility and reactions

- Keep seated click and hover gestures in the avatar frame, separate the knees, and recover the intended overlay position after Windows moves it. Exclude the desktop shell and maximized captioned windows from fullscreen suspension.

## Studio widget controls and Midnight Nocturne

- Persist the themed title bar and theme animations. Organize widget settings into four sections and save edits automatically for the live renderer.
- Keep Godot outside the taskbar. Start its transparent surface offscreen, retain the ReflexCore launcher as the visible app, and align standing feet with the taskbar.
- Add Midnight Nocturne with new ear and outfit geometry, longer hair and three refinements to the seated motion. Free Roam waits for attention before leaving a cloud.

## ReflexCompanion seated motion and interaction

- Install Midnight Atelier Refined as the default barefoot edition when its local assets are present.
- Give clicks and drags priority over autonomous movement. Let Free Roam leave a cloud rest for a short walk. Show the ReflexCore icon on the Windows taskbar.
- Refine the Atelier proportions, face textures, hair, seated poses and restrained leg motion.

## ReflexCompanion Midnight Atelier

- Add a separate visually upgraded VRM edition with fitted harness panels, a bevelled crest, sculpted hair, new eye and face textures, and a lightweight toon material.
- Add a surprised expression and soften the window-seat wrist and ankle poses for Atelier.

## Windows launcher

- Add a native windowed launcher, a shared ReflexCore icon, and a desktop shortcut installer. Launch Studio directly and keep PowerShell consoles off the taskbar.

## Citadel visible deployment

- Calibrate Windows cursor drags using the browser pixel ratio and keep the deck card and target on screen. Stop safely if the browser moves or either point is covered.
- Verify deployments from a game snapshot taken at placement, before waiting for 3D frames. Record the failed stage and reason in Agent Observability and Export Trace. Hold the start control until a cancelled run finishes cleanup.

## ReflexCompanion Midnight Edition

- Add a separate skinned shorts and fitted-top VRM with bare feet and optional dark stockings.
- Add persistent Midnight sitting styles and intensity. The active overlay switches local VRMs in place.

## Companion menu and seated hem

- Allow an outside body press to dismiss the menu and start a drag immediately. Shape each seated front and side skirt segment independently.

## Companion seating reactions

- Preserve mounting and landing poses during clicks and reduce seated skirt lift.

# Changelog

## Unreleased

* Retire the legacy 2D avatar while keeping the Classic telemetry widget and its position.
* Add a tray switch to restore 3D mouse interaction after click-through is enabled. Extend the avatar's grab area to the outfit and occupied cloud.

* Replace the companion's native context popup with an overlay menu that releases clicks outside its controls.
* Limit native hit-testing to the visible companion area on Windows. Align the seated legs and ankles to the avatar's forward axis.

* Keep the full avatar inside the transparent viewport during throws. Allow immediate re-grabbing during falls, climbs and cloud seating.
* Refine seated poses for window edges and clouds. Align the hips to the actual support in screen space.

* Restore Classic and 3D widget visibility on launch, save pending widget changes on close and add top-level Restart and Exit to the tray.
* Preserve a Preview 3D request sent while the previous renderer is still stopping.
* Recover lost mouse releases during companion drags. Let newer gestures preempt older reactions and render magic platforms behind the avatar in 3D.

* Keep the 3D companion seated as its real support window moves. Release on a fast move, window closure or occlusion and restrict climbs to exposed edges within reach.
* Add a procedural approach-to-seat sequence, grounded magic cloud support, damped grabs, directional throws and arm IK for seated reactions.
* Keep seated knees and hands facing forward on the default rig and retain the skirt bone rest transforms.
* Add Studio controls for Magic Platforms, Original and Midnight Edition, and edge smoothing. Add Restart 3D to the tray and hide the renderer from the Windows taskbar.

* Hide the 3D companion's bubble while idle, turn the avatar in its walking direction and remove periodic random pacing. Anchor the seated pose to a reachable window edge.
* Apply clothing changes during the current Godot session. Keep one alternate outfit in memory for switching and defer model imports while the context menu is open.

* Add a private Godot ReflexCompanion 3D renderer, rigged avatar import, desktop physics and independent widget settings in Studio. Allow dragging the existing Classic widget and keep its location across restarts.
* Verify the Windows renderer on the GTX 1650 Ti. Inspect desktop transparency and confirm a real avatar drag and landing. Cover moving and disappearing supports in a deterministic physics test. Document remaining installed UI checks and renderer limits in [ReflexCompanion](docs/REFLEXCOMPANION.md).

### ReflexVision v0.1

* Simplify the tray menu and add a combined Classic and AI Companion mode. Keep hardware metrics visible together and reserve the companion bubble for task activity in combined mode.
* Match the theme in the Agent queue and Models controls, reduce duplicate Agent actions, and apply the gallery's smooth scrolling to hosted pages.

* Add AI Companion as an optional tray widget mode with an original animated avatar, live status and replaceable local poses.

* Show each physical GPU separately in the tray HUD with utilization, dedicated video memory and shared memory usage. Join Windows GPU counters to DXGI adapters by LUID.

* Add a Windows preview with low-copy capture, classical HUD and scene cues, confirmed track IDs, bounding boxes, adaptive cadence and an independent stop signal.
* Expose fresh typed observations through the existing CS16 command. Validate blank, lost and stale observations.
* Add the separate offline Plant Drill and display the controlled player's real route and progress. Verify planting inside the isolated GoldSrc fixture using the server event.
* Translate Studio, Shared Control, the tray and browser Citadel to English. Display live CPU, RAM, GPU, VRAM and recent model throughput in the tray HUD.

* Add a Counter-Strike 1.6 benchmark that measures one actor's rounds using GoldSrc server events. Report plant evidence, spawn and freeze-end timing, failures and optional easy-bot results.
* Add loopback listen-server discovery, GoldSrc demo pose parsing and bounded waypoint drafting and validation. See [CS 1.6 offline benchmark](docs/CS16-BENCHMARK.md).
* Generate walking routes from an installed GoldSrc BSP and validate the standing hull and target volume. Static checks passed for both Dust II plant volumes.

## 0.7.1-alpha.2 · Supervised desktop queue

* Queue Studio's UIA and two Notepad actions in the existing tray. Keep a bounded local history with selected approval and cancellation.
* Serialize workers across tray generations. Require fresh approval for old pending jobs and record lost claims as interrupted.
* Preload a cold visual model before opening the owned editor. Poll for cancellation during local inference and revalidate the foreground before input.
* Exercise the real Studio buttons, separate worker processes, stop and recovery on Windows. See [acceptance measurements](docs/BENCHMARKS.md).

## 0.7.1-alpha.1 · Experimental

* Route a new-file Notepad task through Windows UI Automation, with an optional Ollama visual check and native Unicode editing fallback. Verify both the editor and the saved file.
* Retain verified editor methods. Add a bounded SQLite reliability estimator to the manifest-driven Rust Goal Agent. Index outgoing edges during planning.
* Use the selected local model and bounded settings for visual requests. Add a reproducible 2B/4B comparison.
* Add a visible Notepad task control, host CPU and available RAM, visibility-aware diagnostics, and a six-page WinForms smoke test.
* Port the zxcLagLab WPF navigation, material and control templates, original theme data and artwork, gallery, scrolling, and window controls to the public ReflexCore Studio. Preserve the six operator panels through an in-process WindowsFormsHost.

The prior Windows source identified itself as VisionLoop 0.7.0 Preview3 FIX4. Its Rust package manifest still reported 0.1.0. See docs/BENCHMARKS.md for the measured baseline.
