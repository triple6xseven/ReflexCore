# ReflexCore Engine

Local-first Windows automation for PCs with limited RAM and GPU capacity. ReflexCore uses a Rust planner and native Windows UI Automation to execute supported tasks, check their results and reuse successful methods. Ollama is optional for tasks that need visual input.

**Status: early alpha.** Today, ReflexCore runs a small set of verified desktop tasks. General desktop automation and autonomous gameplay are still in development.

## What works today

- **Plan, act and verify.** The built-in Windows UI Automation scenario runs a sequence of actions and checks the resulting state. The Notepad skill creates a new file and verifies its contents from disk.
- **Reuse successful methods.** The Notepad skill verified 20 of 20 files in a local Windows test, with zero model calls. Median execution time was 746 ms after the supervisor started. See [benchmark methodology](docs/BENCHMARKS.md).
- **Supervise tasks in Studio.** Submit built-in tasks, cancel pending work and inspect a local task history. See [Studio](docs/STUDIO.md) and [queue recovery](docs/QUEUE.md).

## What we are building next

Expand the verified skill catalog and measure reliability on real tasks. The offline CS 1.6 experiment can score game logs and calculate routes through Dust II. Its isolated controller has verified spawn with C4. Autonomous movement, planting and winning against a bot are pending. See the [game benchmark](docs/CS16-BENCHMARK.md).

## Build from source

On Windows 11, use the Rust MSVC toolchain, Visual C++ Build Tools, the .NET 8 SDK, the .NET Framework 4.8 targeting pack and Windows PowerShell 5.1.

~~~powershell
cargo build --release --locked
dotnet build .\ui\ReflexCore.Studio.csproj -c Release
powershell.exe -NoProfile -File .\tools\Start-ReflexCore.ps1
~~~

In Studio, open **Агент** and select **БЛОКНОТ · СОЗДАТЬ ФАЙЛ** to try the new-file task. Keep the new Notepad window in the foreground.

Start with the [runtime architecture](docs/COGNITIVE-RUNTIME.md), [changelog](CHANGELOG.md), or [contributor notes](AGENTS.md). ReflexCore is [MIT-licensed](LICENSE).
