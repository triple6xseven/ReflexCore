# Changelog

## 0.7.1-alpha.1 · Experimental

* Route a new-file Notepad task through Windows UI Automation, with an optional Ollama visual check and native Unicode editing fallback. Verify both the editor and the saved file.
* Retain verified editor methods. Add a bounded SQLite reliability estimator to the manifest-driven Rust Goal Agent. Index outgoing edges during planning.
* Use the selected local model and bounded settings for visual requests. Add a reproducible 2B/4B comparison.
* Add a visible Notepad task control, host CPU and available RAM, visibility-aware diagnostics, and a six-page WinForms smoke test.
* Port the zxcLagLab WPF navigation, material and control templates, original theme data and artwork, gallery, scrolling, and window controls to the public ReflexCore Studio. Preserve the six operator panels through an in-process WindowsFormsHost.

The prior Windows source identified itself as VisionLoop 0.7.0 Preview3 FIX4. Its Rust package manifest still reported 0.1.0. See docs/BENCHMARKS.md for the measured baseline.
