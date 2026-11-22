# ReflexCore Engine

ReflexCore is a local Windows task engine with a Rust goal planner, Windows UI Automation executors and an optional Ollama vision model. The experimental 0.7.1-alpha.1 release can complete and independently check a new-file task in Windows Notepad.

## First run

On Windows 11, install the Rust MSVC toolchain and Visual C++ build tools. Use Windows PowerShell 5.1, a recent .NET SDK (tested with SDK 8) and the .NET Framework 4.8 targeting pack for WPF Studio. Ollama is optional for the native task. The browser simulation tests use Node.js.

~~~powershell
cargo build --release --locked
dotnet build .\\ui\\ReflexCore.Studio.csproj -c Release
powershell.exe -NoProfile -File .\tools\Start-ReflexCore.ps1
~~~

The WPF Studio shell includes the 45 original zxcLagLab themes. **Оформление** opens the searchable gallery and the controls for material, wallpaper, typography, motion and window chrome.

In **Агент**, select **БЛОКНОТ · СОЗДАТЬ И ПРОВЕРИТЬ ФАЙЛ**. The task opens a new uniquely named text file on the desktop, checks the focused editor, writes a fixed sample and reads the saved file. Keep its window in the foreground. The stop button and tray emergency stop are available during the task. **Модели** manages local Ollama models. **Диагностика** displays stage, host CPU, available RAM and named process groups.

## Running from the terminal

~~~powershell
# Read-only symbolic plan, then execute the verified WinForms fixture.
.\target\release\reflexcore.exe agent plan .\examples\goal_agent_demo.json
.\target\release\reflexcore.exe agent demo --execute

# Visible Notepad task, with optional visual corroboration on the second command.
powershell.exe -NoProfile -File .\tools\ReflexCore-VisionLoop.ps1 -Action DemoNotepad -AllowInput
powershell.exe -NoProfile -File .\tools\ReflexCore-VisionLoop.ps1 -Action DemoNotepad -AllowInput -Route Visual

# Validate the build and exercise actual Windows controls.
cargo test --locked
powershell.exe -NoProfile -File .\tools\ReflexCore-ControlCenter.ps1 -SelfTest
powershell.exe -NoProfile -STA -File .\tools\ReflexCore-ControlCenter.ps1 -UiSmoke
powershell.exe -NoProfile -File .\tasks\Test-NotepadSkill.ps1 -Runs 20 -AllowInput
~~~

The Rust planner accepts versioned goal and flow manifests. It learns route reliability from completed executions. The Notepad executor learns a verified editor method. Neither starts a background training job. Generated state under data/ and per-user runtime directories belongs to the local installation. The optional cloud API page requires separate configuration and an explicit action.

See the [architecture](docs/COGNITIVE-RUNTIME.md), [benchmarks](docs/BENCHMARKS.md), [upstream research](docs/COMPETITOR-RESEARCH.md) and [dependency notices](docs/ATTRIBUTION.md).
