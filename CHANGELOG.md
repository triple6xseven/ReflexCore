# Changelog

## Unreleased

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
