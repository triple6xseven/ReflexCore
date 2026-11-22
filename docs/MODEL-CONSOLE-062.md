### FIXED5 — lease verification and time handling

The 1–240 minute selector starts a bounded lease. Success is returned only after `/api/ps` confirms the model is resident. The UI shows the exact model, local expiration clock and live countdown, separately from the short-lived loader process. If another client shortens Ollama's idle TTL, a low-cost empty-prompt reassertion can extend it within the original deadline. If the model disappears, do not auto-reload; report early unload. Events omit prompts and UI text. In Performance Lab, timestamps display computer-local time but UTC remains stored and sortable.

## FIXED4 recovery from parser regression
FIXED3 failed staged `Parser.ParseFile` for model manager on Windows and did not install. FIXED4 uses the FIXED2 Windows-parsed script as the base and replaces only the model ID regex, with 13 invalid and four valid self-test vectors. The staged guard runs *before* source mutation in both supported parameter forms. Rust, IPC, Citadel and Shared Control code unchanged.

# ReflexCore 0.6.2 — unified UI, model tuning and reproducible Qwen baseline

## FIXED1 integration note
Windows 0.6.2 original installer failed during combined C# compilation because `ReflexCore.Control` namespace shadowed unqualified `Control` in Diagnostics. FIXED1 qualifies WinForms Control in Diagnostics and ModelPanel, preserving original 0.6.1 source-lock, tests and rollback. No change to model behavior or performance; interactive Windows acceptance remains necessary.

## FIXED2 installer/runtime CLI contract
The FIXED1 Windows installation reached the model guard check but failed because the installer called `ReflexCore-Models.ps1 -SelfTest` while only `-Action SelfTest` was declared. All previous C# self-tests passed, and automatic rollback restored 0.6.1. FIXED2 accepts both forms, rejects conflicting `-Action`, runs both offline guard self-tests during install and validates the declared self-test parameters using the PowerShell parser before touching source files. The model API/normal model lifecycle actions are unchanged.

## User-visible behavior
- One Control Center, one tray icon. `Start-ReflexCore.ps1` opens / focuses the Control Center. `-Mode Diagnostics` selects embedded Diagnostics in the **same** WinForms app. Shared Control is an explicitly launched separate safety-controlled fixture, not a second tray.
- Models tab lists Ollama installed and currently loaded models from loopback `/api/tags` + `/api/ps`; refresh is opt-in. Start warms one selected local model via `/api/generate` empty prompt. Minutes [1,240] = wall-clock deadline from successful load, with a background watchdog. `keep_alive` matches the initial duration as an additional idle fallback, not a hard inference timeout.
- STOP MODEL unloads one ID; STOP ALL requests tray-owned job stop, cancellation of Shared Control via `global-stop.signal`, and unload of every model in Ollama `/api/ps`. Ollama may be used by other applications: pressing STOP ALL disrupts their loaded model cache too. It does **not** terminate arbitrary OS processes, disable login tasks, guarantee an in-progress model call is instantly preempted, or stop arbitrary browser JS.
- Settings use private `data/settings/ollama-local.json`, schema `reflexcore.ollama.settings.v1`, and are read on each Shared Control inference. `Temperature`, `num_ctx`, `num_predict`, `top_p`, `keep_alive_minutes` are in Basic; `top_k`, `repeat_penalty`, `num_thread`, `num_gpu`, `seed` in Advanced. All are range checked before being sent to Ollama. Existing unrelated OpenAI and Citadel model selection is unchanged.

## Benchmark & telemetry
`tools/Benchmark-ReflexQwen.ps1 -Runs 3 -Warmups 1` runs the **same fixed text-only prompt** through local Ollama Qwen and checks that the returned JSON has exactly the expected two keys and values. This is not a computer vision benchmark or a substitute for the WinForms UIA goal test. It records actual total Ollama wall time, supplied prompt/eval durations, and number of successes (failed runs are not counted as fast successes). Fixed parameters and task are fingerprinted `config_sha256` so comparisons remain auditable.

Private results: `%LOCALAPPDATA%\ReflexCore\diagnostics\model-bench\latest.json` plus bounded `history.jsonl`; UI reads the latest model benchmark together with real Shared Control navigation telemetry. The export tool selectively includes only safe metrics, model identifiers and bounded options; no screenshots, prompts, model outputs, UI selectors or personal window contents.

## Scope and tests
- Installing uses SHA-256 exact source checks against user-reported 0.6.1, backup in local application data, controlled self-tests, rollback. Does not start models, run UI tests or request GPU during install.
- Manual acceptance after install: verify one Control Center window and one tray icon; select Models, refresh Ollama, start a known installed model for 1 minute and observe load / unload; test STOP ALL when Shared Control is idle, then explicitly test cancellation with permission, then run fixed Qwen benchmark and inspect resource telemetry. If any phase fails, attach sanitized export and report the stage; do not treat compilation as proof of behavior.
- Safety: no admin, no remote endpoints, no model-origin shell commands, no unrecoverable process kill of unrelated apps. Existing emergency hotkeys remain authoritative.

- The existing UIA Measurement Lab checks `global-stop.signal` during its 150ms polling and terminates only the Rust/fixture process tree it created. Qwen HTTP calls from other apps may need to return or time out; Stop All is best-effort rather than a universal OS kill switch.
