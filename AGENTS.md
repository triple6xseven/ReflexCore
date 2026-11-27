# ReflexCore contributor notes

Follow [the engineering roadmap](docs/ROADMAP.md) for milestone scope and order.

For queue changes run tasks/Test-Queue.ps1. With a release build and an interactive desktop, add -AllowInput for actual UIA and Notepad verification. Add -VisualCancellation with the local default vision model installed to exercise stop during inference.

Use Windows PowerShell 5.1 for the WinForms tools. Build with cargo build --release --locked and run cargo test --locked. Compile the combined Control Center after editing its C# sources. Run the visible UI smoke and fixture tests on an interactive Windows desktop.

Use locally owned synthetic fixtures. Verify effects by reading the output independently. Keep editor identity, foreground ownership, explicit consent, stop controls and typed protocols intact. Store runtime state and models outside Git. The WPF Studio project targets .NET Framework 4.8 and hosts all six live operator pages. Build it with dotnet build ui/ReflexCore.Studio.csproj -c Release. Public diagnostics contain bounded structural measurements. Review staged files and Git identity before publication.

The component map is in docs/COGNITIVE-RUNTIME.md. Update the benchmark report when changing policy, timing or validation. Keep third-party license notices and inspect model licenses separately.
## Autonomous engineering

Proceed independently on routine work authorized by the current development request, including implementation, configuration updates, migrations, dependencies, builds, tests, and scoped Git operations. Choose reasonable defaults, create backups and rollback paths for local changes, and resolve recoverable errors without handing routine decisions back to the operator. Avoid multiple-choice questionnaires for engineering decisions. Request input only when required by a genuine permission boundary, material ambiguity, or irreversible action. Continue independent work if a platform permission blocks one step. Preserve unrelated data and existing security controls. Report consequential decisions after execution.
