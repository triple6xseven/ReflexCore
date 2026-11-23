# ReflexCore Studio

The primary launcher opens one WPF window hosting all six existing control panels in the same Windows PowerShell process. The original single-instance mutex and tab requests still select an existing window. **Appearance** is a seventh, native WPF page. The .NET Framework 4.8 host shares a CLR with the existing WinForms controls. The build uses the .NET SDK's C# compiler.

| Source component in zxcLagLab | ReflexCore integration |
|---|---|
| Themes, StudioMaterials, ThemeStyles | Original 45 themes, WPF control templates, theme colors and material buttons |
| StudioShell | Adapted navigation rail, original navigation template, compact layout, page history, visible stop command |
| AppearanceStudio | Original theme tile and vector preview, search and category filters, material density, artwork selection and typography |
| Controls, Motion, Fx, HackerRain | WPF switches, slider, responsive card layout, spring scrolling, click feedback and opt-in animated background |
| WindowChromeUi | Adapted themed caption with accessible minimize, maximize and close controls |
| Generated artwork | Six project-owned, metadata-stripped PNG resources used for wallpapers and material textures |
| Existing ReflexCore operator controls | Live Agent, Models, Diagnostics, Shared Control, Citadel and OpenAI pages hosted through WindowsFormsHost |

Selecting a theme updates both WPF resources and the hosted page colors. Only an allowlisted theme name is written to the existing per-user theme setting. Other appearance adjustments currently last for the session. Artwork decodes at bounded widths. Opening the agent page does not construct the theme gallery. The WPF host retains the original action handlers and authorization checks. The network test engine, capture drivers and packet-editing pages belong to the other product.

### Verification

The **Agent** page submits **RUN AGENT DEMO**, **NOTEPAD · CREATE FILE**, and **NOTEPAD · CHECK WITH MODEL** to the tray. Select an entry, then use **APPROVE SELECTED** or **CANCEL SELECTED**. The WPF smoke checks those commands using an isolated queue. See [queue and recovery](QUEUE.md).

Build with `dotnet build ui/ReflexCore.Studio.csproj -c Release`. The launcher builds the assembly when it is missing. After editing UI sources run the build again. The Windows UI smoke shows the real window, navigates six hosted pages, opens Appearance, switches all 45 themes in memory, filters the gallery, checks compact navigation and both caption modes, and checks history. It does not write the operator's theme preference.

~~~powershell
powershell.exe -NoProfile -STA -File .\tools\ReflexCore-ControlCenter.ps1 -UiSmoke
~~~

In one stationary Agent-page measurement, about eight seconds per build, the previous shell consumed 203 ms of process CPU and peaked at 106.6 MiB working set. WPF Studio consumed 125 ms and peaked at 160.3 MiB. The measurement includes the PowerShell host. The memory increase was 53.7 MiB. Tests covered the current Windows desktop and two window widths. Additional per-monitor DPI configurations and screen readers have not been qualified.

