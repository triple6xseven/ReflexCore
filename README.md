# ReflexCore Engine EARLY BETA

ReflexCore is a local Windows task engine with a Rust goal planner, Windows UI Automation executors and an optional Ollama vision model. The experimental 0.7.1-alpha.2 release queues verified desktop tasks, retains their outcomes and reuses successful editor methods.

## First run

On Windows 11, install the Rust MSVC toolchain and Visual C++ build tools. Use Windows PowerShell 5.1, a recent .NET SDK (tested with SDK 8) and the .NET Framework 4.8 targeting pack for WPF Studio. Ollama is optional for the native task. The browser simulation tests use Node.js.

~~~powershell
cargo build --release --locked
dotnet build .\\ui\\ReflexCore.Studio.csproj -c Release
powershell.exe -NoProfile -File .\tools\Start-ReflexCore.ps1
~~~

The WPF Studio shell includes the 45 original zxcLagLab themes. **Оформление** opens the searchable gallery and the controls for material, wallpaper, typography, motion and window chrome.

In **Агент**, select **БЛОКНОТ · СОЗДАТЬ ФАЙЛ** to queue a new desktop file. The task checks the focused editor, writes a fixed sample and reads the saved file. Keep its window in the foreground. **БЛОКНОТ · С ПРОВЕРКОЙ МОДЕЛЬЮ** adds a visual check with the configured local model. The queue shows waiting, running and terminal jobs. Select a row to approve or cancel it. After a tray restart, approve pending jobs that should continue. **Модели** manages Ollama models. **Диагностика** displays stage, host CPU, available RAM and named process groups.

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
powershell.exe -NoProfile -STA -File .\tasks\Test-Queue.ps1 -AllowInput
~~~

The Rust planner accepts versioned goal and flow manifests. It learns route reliability from completed executions. The Notepad executor learns a verified editor method. Neither starts a background training job. Generated state under data/ and per-user runtime directories belongs to the local installation. The optional cloud API page requires separate configuration and an explicit action.

See the [architecture](docs/COGNITIVE-RUNTIME.md), [benchmarks](docs/BENCHMARKS.md), [upstream research](docs/COMPETITOR-RESEARCH.md) and [dependency notices](docs/ATTRIBUTION.md).
