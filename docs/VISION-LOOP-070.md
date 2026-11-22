## Active runtime in 0.7.1-alpha.1

DemoNotepad defaults to the guarded native editor route. Use -Route Visual to request the VLM evidence gate in addition to Windows identity checks. Both routes require -AllowInput, an owned foreground editor and exact disk readback. See BENCHMARKS.md for acceptance results. The notes below are historical.

# ReflexCore 0.7.0 — VISION-LOOP PREVIEW2

## Scope and truthful capability claim

This preview adds one independent on-device visual observation loop and **one narrow, supervised Windows Notepad skill**. It does **not** provide an autonomous general-purpose Windows agent, reusable learned skill library, full headless desktop access, or a trained world model.

Existing `ReflexCore-SharedControl.cs` already sends base64 JPEG images to Ollama for a specific CS 1.6 scenario. The new generic Windows preview is additive and does not change Rust, CS16, Citadel, model leases, or the Control Center GUI.

## Components

- `tools/ReflexCore-VisionHost.cs`: a small Win32/C# Notepad foreground guard, in-memory JPEG full-window capture including title/tab chrome, two synthetic JPEG challenges and bounded Unicode SendInput.
- `tools/ReflexCore-VisionLoop.ps1`: PowerShell 5.1 orchestration, localhost Ollama `/api/generate`, JSON Schema response constraints with strict enum validation and one bounded read-only fallback, explicit permission gate, file-readback verification, and status.
- `tools/ReflexCore-Tray.cs`: expands the existing `reflexcore.activity.v1` reader allowlist to the enum `vision_loop`. No changes to the schema fields. This is last-writer-wins with existing producers.

## Exact actions

```powershell
$script = Join-Path ([Environment]::GetFolderPath('Desktop')) 'ReflexCore\tools\ReflexCore-VisionLoop.ps1'
# If Desktop uses OneDrive the returned path already points there.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$script" -Action SelfTest
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$script" -Action Probe -Mode Headless
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$script" -Action Observe -CaptureDelaySec 4
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$script" -Action DemoNotepad -AllowInput
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$script" -Action Stop
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$script" -Action Status
```

### Preconditions

- **Windows 11 interactive session** for `Observe` and `DemoNotepad`.
- Local Ollama at `127.0.0.1:11434`, with a vision-capable model (`qwen3-vl:2b-instruct` by default).
- For `Observe`, switch focus to an existing Notepad window during the countdown; no input is sent.
- For `DemoNotepad`, explicit `-AllowInput` is mandatory. The caller creates an *empty, unique* `ReflexCore-VisionLoop-*.txt` file on Desktop, opens it in Notepad and checks the exact new window title and process before each input action. It sends `Ctrl+A`, a fixed text and `Ctrl+S`, and reads back file bytes. The assistant/model cannot choose arbitrary commands, paths or text.
- An existing file is never overwritten. Failed zero-byte owned demo files are removed, but the script never terminates a user process.

## Verification model

1. **Image transport:** `images: [base64(JPEG bytes)]` in the request body, not the name of a screenshot file. The image is never written to disk.
2. **Probe:** model must correctly label *both* independently generated red and blue synthetic JPEGs. This tests actual pixel-based response, not generic text decoding, but isn't a formal proof of every future observation.
3. **Observe:** Win32 foreground process identity must be `notepad`, followed by model classification (single-value JSON enums (`application`: `notepad`, `other`, `uncertain`; `editable_area`: `yes`, `no`, `unknown`)). Invalid or missing fields are rejected. Visual classification remains fallible.
4. **Demo:** requires explicit CLI permission, unique foreground Notepad target, model-confirmed editor, bounded fixed input, then independently read-back exactly `ReflexCore is operational`. Dispatch of SendInput is **not** considered success.
5. **Cancellation:** focus guard before each key, operator `-Action Stop` checked before/after Ollama and between stages; existing tray STOP ALL global-stop signal is respected. A synchronous in-flight Ollama HTTP call may not cancel until timeout; `Ctrl+C` exits the PowerShell process. The tray **Ctrl+Alt+P** hotkey controls supervised jobs only and is not guaranteed to stop this direct script. Timeout defaults to 120 seconds.

## Privacy and resource usage

All inference uses loopback Ollama; no external network URL. No image, prompt, response, window title or full UI text is stored in tracked files. Sanitized enum-only stage snapshots are written to `%LOCALAPPDATA%\ReflexCore\runtime\vision-loop-status.json` and the pre-existing `activity.json`. These may be overwritten by other producers. Input is opt-in; no administrator rights or external process killing. Desktop demo file contains only the fixed text and is visible to the user.

Vision host resizes JPEG to up to 640 pixels wide by default, `num_ctx=2048`, `num_predict=100`, `temperature=0`. The model may still allocate substantial VRAM (~3GB for the user's existing Qwen). Do not automatically preload a second model or assume it was running. No claim of faster agent reasoning or autonomous learning is made by this release.

## Test matrix

| Test | Expected |
|---|---|
| `-Action SelfTest` | C# compiles, SendInput ABI size and image fixture tests, model response allowlist; no screen, input or Ollama |
| `-Action Probe -Mode Headless` | 2/2 actual JPEG red/blue classifications |
| `-Action Observe` focused on Notepad | image sent, strict JSON, no input |
| `-Action Observe` focused on Chrome | refused before capturing/sending screenshot |
| `-Action DemoNotepad` WITHOUT `-AllowInput` | fails before starting app or creating file |
| `-Action DemoNotepad -AllowInput` | fixed text saved via UI and exact content verified from disk |
| Switch foreground during Demo | input blocks; incomplete result never marked verified |
| `-Action Stop` or tray STOP ALL | subsequent stages reject; HTTP request may finish before seeing stop |
| Tray | `vision_loop` stage readable; old `citadel_rust` and `shared_control` still valid |
| Rollback | compares installed hashes, restores pre-install docs/tray and deletes new scripts |

## Known limitations / future work

- Notepad on Windows 11 may open existing tabs and modern UI layout varies. A window title mismatch or uncertain VLM response safely rejects input. User confirmed PREVIEW1 launched Notepad but the model returned a value rejected by the strict application enum. PREVIEW2 adjusts the visual contract and captures full-window chrome; **the corrected Windows integration is not yet verified**.
- No full image OCR validation or UIA target matching beyond exact Notepad window identity; repeated clicks/keyboard actions are not generalized.
- True Headless screen capture is not implemented; the Headless Probe tests Ollama without a display.
- STOP via `-Action Stop` is cooperative, not instant during synchronous model HTTP.
- Next: integrate OS UIA evidence, per-action structured result, supervised launch/cancel, and skill cache guarded by measured pre/postconditions; compare identical deterministic tasks with `docs/MEASUREMENT-LAB.md` methodology.

## Preview2 regression fix (21 November 2026)

- Confirmed on operator Windows: Preview1 installed, both synthetic VLM JPEGs correctly classified, but `DemoNotepad` failed with `VLM application enum rejected` before any text input. The exact rejected string is unavailable because raw inference output is deliberately not logged.
- Fix: do not put pipe-delimited values inside model example fields. Use a clearly enumerated prompt and an Ollama JSON Schema for an exact two-key response. A single read-only retry with plain JSON is allowed if schema/shape fails; a reply saying `other`, `uncertain`, `no`, or `unknown` never authorizes typing.
- Normalize only distinct known aliases like `Microsoft Notepad` and capitalization; compound/unknown labels remain rejected.
- Capture entire foreground Notepad window (including title and tab chrome) instead of client area alone, while retaining Win32 process identity, unique token, foreground, size and keyboard restrictions.
- Includes negative unit tests for pipe-joined, comma-joined and unrelated app labels. No screenshots, file titles or raw model answers are persisted.
- Incremental installer is SHA-locked to unmodified Preview1 VisionHost/VisionLoop/docs. Creates a separate private recovery snapshot; rollback restores Preview1. After rollback Preview1's original rollback mechanism remains usable.
- No changes to `ReflexCore-Tray.cs`, Rust, Citadel, Shared Control, Ollama settings, model lease, GUI or other unrelated code.

### Acceptance tests

1. Run incremental installer with `-VerifyOnly` and then normally. Verify PowerShell AST, C# compile and offline self-tests pass.
2. Run `-Action Observe` while Notepad is foreground. It must either report `notepad`/`yes` or safely refuse; no keyboard input.
3. Run `-Action DemoNotepad -AllowInput`, verify exact file bytes and `VERIFIED`; switch focus during inference to test fail-closed behavior.
4. If supported by installed Ollama/model, first classification uses JSON Schema; fallback can add an inference call and latency. No performance claims until measured.


## Preview3 / resource ownership, UIA, HUD (21 Nov 2026)

- Windows operator reported Preview2: VLM returned a safe negative/uncertain classification; no input was sent. All 2 synthetic JPEG probes passed in Preview1.
- Optional Windows UI Automation evidence: an explicitly approved demo may proceed when VLM is uncertain only if unique foreground Notepad PID/title and a focusable editable UIA element are independently confirmed. Explicit model `other` or `no` always blocks. Demo success labels distinguish VLM-confirmed versus OS-only evidence.
- Ollama `/api/ps` checks whether the model was preloaded before a VisionLoop task. On exit, the task requests unload via local `/api/generate` `keep_alive:0` only when the model was not preloaded, or with explicit `-UnloadModelAfter`. If the ownership check fails, preservation is safer by default. This is not a process kill and cannot guarantee exclusive ownership in the presence of concurrent clients.
- Activity stages and last completed response tokens/sec use Ollama `eval_count / eval_duration`. No live streaming throughput is claimed. Tray HUD reads allowlisted enums and bounded numeric telemetry only. HUD suspends while screenshots are taken to avoid polluting visual input.
- New Desktop `ReflexCore-Latest.bat` opens `tools/Start-ReflexCore.ps1` in current installed Desktop project. It does not download updates and does not select older numbered folders. Existing running tray needs menu Exit tray before launcher loads the updated tray C# implementation.
- Original zxcLagLab, Rust, Citadel and Shared Control are untouched.

## Preview3 FIX2: PowerShell 5.1 UIA compiler reference fix

- First Windows Preview3 install attempt stopped at pre-install SelfTest: `Metadata file UIAutomationClient.dll could not be found`. No project files were installed.
- Host loader now loads trusted installed .NET Framework assemblies by simple assembly name, resolves their actual `.Location`, and passes **absolute existing DLL paths** to `Add-Type -ReferencedAssemblies`. It does not download DLLs, request elevation, disable UIA, or weaken any input guard.
- Preflight C# compilation and negative parser tests still run before backups and file changes. Full Windows integration still requires operator test.


## Preview3 FIX4 — limited UIA-authoritative identity correction (2026-11-21)

User Windows result: `VLM app=other; editable=yes; Windows UIA editor=True; Ollama=85.4 tok/s`, followed by the earlier `VLM explicitly rejected target` guard. This proved visual app misclassification, not failure of actual Windows OS editor identification. It did **not** prove end-to-end text entry/save.

The new `Get-NotepadDemoGate` explicitly separates the **classification metric** from the **action safety gate**. For `DemoNotepad -AllowInput` only, when `application=other` and `editable_area=yes`, verified OS foreground `notepad.exe` + unique random file-name token + UIA editable field may allow the fixed text action. The console reports `VLM APP CLASSIFICATION CONFLICT`; if disk bytes match, the result is `UIA + NOTEPAD + SAVE: VERIFIED; VLM APPLICATION CLASSIFICATION FAILED`. This cannot be counted as full VLM visual recognition success.

The following remain blocking: no `-AllowInput`, model `editable_area=no`, UIA=false, app=other with no verified editable-area evidence, invalid model JSON, unexpected process/title, lost foreground, operator stop, readback mismatch. VisionHost and tray are not changed by this fix. Unload behavior stays opt-in with `-UnloadModelAfter` (selected model only).

Local test: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <VisionLoop.ps1> -Action DemoNotepad -AllowInput -UnloadModelAfter`. Installer performs AST + C# + offline policy matrix checks before writing any file. Real Windows task remains unverified until a post-install test.
