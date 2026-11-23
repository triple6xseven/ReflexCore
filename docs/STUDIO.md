# ReflexCore Studio

The primary launcher opens one WPF window hosting all six existing control panels in the same Windows PowerShell process. The original single-instance mutex and tab requests still select an existing window. **Appearance** is a seventh, native WPF page. The .NET Framework 4.8 host shares a CLR with the existing WinForms controls. The build uses the .NET SDK's C# compiler.

| Source component in zxcLagLab | ReflexCore integration |
|---|---|
| Themes, StudioMaterials, ThemeStyles | Original 45 themes, WPF control templates, theme colors and material buttons |
| StudioShell | Adapted navigation rail, original navigation template, compact layout, page history, visible stop command |
| AppearanceStudio | Original theme tile and vector preview, category filters, material density, artwork selection and typography |
| Controls, Motion, Fx, HackerRain | WPF switches, slider, responsive card layout, spring scrolling, click feedback and opt-in animated background |
| WindowChromeUi | Adapted themed caption with accessible minimize, maximize and close controls |
| Generated artwork | Six project-owned, metadata-stripped PNG resources used for wallpapers and material textures |
| Existing ReflexCore operator controls | Live Agent, Models, Diagnostics, Shared Control, Citadel and OpenAI pages hosted through WindowsFormsHost |

Selecting a theme updates both WPF resources and the hosted page colors. Only an allowlisted theme name is written to the existing per-user theme setting. Other appearance adjustments currently last for the session. Artwork decodes at bounded widths. Opening the agent page does not construct the theme gallery. The WPF host retains the original action handlers and authorization checks. The network test engine, capture drivers and packet-editing pages belong to the other product.

### Verification

The **Companion & Widgets** page includes Character, Editor, Movement, Classic, and Advanced sections. Edits save automatically and apply to the running overlay. In Editor, choose parts from the wardrobe and use Apply to save them as a Custom character. The themed title bar and theme animations stay saved across Studio sessions. Drag Classic from its background or text when it is unlocked. See [runtime setup and model requirements](REFLEXCOMPANION.md).

Open the ReflexCore tray icon and choose **Widget → Show Classic**, **Show ReflexCompanion 3D**, or **Show Both**. Classic shows the hardware and Ollama metrics. With both visible, the 3D bubble reports work and the queue. **Ctrl+Alt+H** shows or hides Classic. Use **Widget → 3D mouse interaction** to restore the avatar’s drag and context menu after enabling click-through.

The **Companion & Widgets > Advanced > Windows activity notifications** toggle controls the Windows PowerShell 5.1 notifications from ReflexCore. It defaults to off. Opening the 3D companion keeps the current Classic widget visibility.

**Appearance → Smooth scrolling** controls both the theme gallery and the scrollable hosted pages. The hosted pages reuse the same damped spring as the zxcLagLab gallery. Lists, model pickers and numeric editors keep their native wheel behavior.

Select a local VRM or GLB in **Companion & Widgets**, or use **Edition** to choose between the installed Original and Midnight VRMs.

The **Agent** page submits **RUN AGENT DEMO**, **NOTEPAD · CREATE FILE**, and **NOTEPAD · CHECK WITH MODEL** to the tray. Select an entry, then use **APPROVE SELECTED** or **CANCEL SELECTED**. The WPF smoke checks those commands using an isolated queue. See [queue and recovery](QUEUE.md).

Build with `dotnet build ui/ReflexCore.Studio.csproj -c Release`. The launcher builds the assembly when it is missing. After editing UI sources run the build again. The Windows UI smoke shows the real window, navigates six hosted pages, opens Appearance, switches all 45 themes in memory, filters the gallery, checks compact navigation and both caption modes, and checks history. It does not write the operator's theme preference.

~~~powershell
powershell.exe -NoProfile -STA -File .\tools\ReflexCore-ControlCenter.ps1 -UiSmoke
~~~

In one stationary Agent-page measurement, about eight seconds per build, the previous shell consumed 203 ms of process CPU and peaked at 106.6 MiB working set. WPF Studio consumed 125 ms and peaked at 160.3 MiB. The measurement includes the PowerShell host. The memory increase was 53.7 MiB. Tests covered the current Windows desktop and two window widths. Additional per-monitor DPI configurations and screen readers have not been qualified.

