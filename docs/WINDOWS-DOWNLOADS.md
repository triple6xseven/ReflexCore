# Windows downloads

The Windows x64 preview includes the compiled Rust core, Studio assembly, Godot 4.7.2, the selectable Original and ZXC companion assets, and a signed Microsoft .NET Framework 4.8 offline redistributable.

- **Portable.** Extract the entire ZIP to a writable folder and open `ReflexCore/ReflexCore.exe`. Windows 11 already includes a compatible Framework. For a Windows installation without it, run `Prerequisites/net48.exe` first.
- **Setup.** Open the installer to deploy the app in a dedicated folder and create a Start menu shortcut. It offers the Microsoft prerequisite when Framework 4.8 is missing. Installing over a populated folder is disabled.
- The clean profile starts the ZXC companion at 100% scale with white 40 den stockings, Glass bubbles, and the topmost and fullscreen options enabled. Free Roam is used for the packaged default. The companion data is isolated under the packaged app's `data/companion3d`.
- Optional Ollama models and the local CS 1.6 server, game files and Python launcher are separately configured. Private model-source files, logs, saved settings and recordings are excluded.
- The ReflexCore setup and portable launcher are unsigned. Microsoft Defender SmartScreen may display a reputation warning. Compare the SHA-256 of your download with the published checksum before running it. [Release checksums](https://github.com/triple6xseven/ReflexCore/releases/download/v0.7.1-alpha.2-windows.1/SHA256SUMS.txt).

## Building the packages

Current packaging requires a clean tracked tree and records the source commit in `ReflexCore/SOURCE-REVISION.txt` inside the ZIP and setup payload.

From the [release source revision](https://github.com/triple6xseven/ReflexCore/tree/c972406), run `packaging/Build-WindowsRelease.ps1` with Windows PowerShell 5.1 and the project's normal Rust and .NET build prerequisites. Supply the official Godot 4.7.2 executable, the approved distribution copies of the Original and ZXC VRM pairs, a signed .NET 4.8 offline installer and an empty output directory. See [avatar attribution](COMPANION-ASSET-LICENSE.md).

[Godot licensing](https://docs.godotengine.org/en/4.7/about/complying_with_licenses.html) · [Microsoft Framework installation guidance](https://learn.microsoft.com/en-us/dotnet/framework/install/on-windows-10)
