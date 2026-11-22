# Changelog

## Unreleased

### Offline practice experiment

* Add an isolated AMX Mod X adapter, Rust waypoint driver, and original de_reflex_lab map generator. The loopback test verified startup, fake-client spawn and engine-issued C4. The movement test stopped when the GameDLL kept the actor at maxspeed 1.00, including with a stationary CT present. Plant and bot win remain unverified.
* Resume with neutral player ticks after team/class selection. Read the real joining state and speed before restarting the round. Keep normal movement and plant rules. Re-run the original fixture before Dust II.
* The tested server uses Valve steam_legacy assets, ReHLDS 3.15.0.896, Metamod 1.21.1-am and AMX Mod X 1.10.0.5488. Set the isolated server's `rc_practice_enabled` and `sv_lan` to 1, use `+ip 127.0.0.1 +servercfgfile rc-practice.cfg +map de_reflex_lab`, and load the compiled Pawn adapter through AMX Mod X. Run `cs16 practice <mailbox> <route.json> --allow-offline --stationary-opponent`. Use the actual server log to score the result.

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
