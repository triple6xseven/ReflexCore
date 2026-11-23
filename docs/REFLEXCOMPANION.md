# ReflexCompanion 3D

Open **Companion & Widgets** in Studio. **Preview 3D** starts the renderer and applies pending settings. **Stop** closes the renderer owned by ReflexCore. Classic can stay visible independently. Drag Classic from its labels or background when position is unlocked and click-through is off. **Reset position** returns it to its default corner.

With the 3D avatar visible, drag the body to move it. Release after a quick movement to throw it when physics is enabled. Stroke across the head for a pet reaction. Double-click the avatar to greet it. When click-through is enabled, use Studio to turn it off. Taskbar, Window edges and Free roam use screen work areas and currently visible window edges as surfaces.

## Windows setup

Install Godot 4.7.2 for Windows from the [official release](https://github.com/godotengine/godot/releases/tag/4.7.2-stable). Use the standalone Windows executable. The renderer uses Godot Compatibility and GDScript. The tray and Studio retain their .NET Framework 4.8 build. VRoid Studio can author replacement models. Running the widget does not require VRoid Studio, a Python process or Ollama.

From the project directory, register the local renderer and avatar files.

~~~powershell
powershell.exe -NoProfile -File .\tools\Register-ReflexCompanion.ps1 -Godot <Godot.exe> -Avatar <stockings.vrm> -BareLegsAvatar <bare-legs.vrm>
~~~

Restart ReflexCore or use **Preview 3D** from the updated Studio. User-installed models and the Godot executable stay outside Git. To reproduce the adapted Lumen VRMs, use Python 3, NumPy and Pillow to run `python examples/build_companion_avatar.py --download --output export`. The builder verifies the pinned upstream asset first. See [asset provenance](COMPANION-ASSET-LICENSE.md).

## Asset contract

Use a local VRM or self-contained binary GLB with a humanoid skeleton and head, hips, upper-arm and upper-leg roles. Blend shapes improve facial expressions. Rig names, channels and embedded animation support vary by model. The built-in Lumen presets share the same rig and differ in body textures. Studio can choose a third-party model independently. Use a model with permission to use and redistribute as applicable. Preserve its license metadata.

## Runtime boundaries

The existing tray starts one Godot process on demand and stops that exact child. Studio writes bounded settings and explicit lifecycle commands. The tray publishes real task stages, queued-job counts and current metrics using the existing activity and resource counters. Window data consists of visible, non-cloaked DWM rectangles, without captions or identifiers. The renderer reads the latest snapshot on a bounded cadence and pauses for fullscreen foreground windows or ReflexCore capture. When Classic is visible, the companion speaks only about workflow.

Godot loads glTF meshes and skinning, reads VRM humanoid roles and expressions, and uses conservative local bone poses and secondary motion. Custom MToon shading, role mapping and the Windows transparent-overlay implementation were informed by the [Godot application guide](https://docs.godotengine.org/en/stable/tutorials/ui/creating_applications.html), [Godot VRM](https://github.com/V-Sekai/godot-vrm) and [Godot Clickthrough](https://github.com/KitzuGG/Godot-Clickthrough). Window surfaces use [DWM frame bounds](https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/nf-dwmapi-dwmgetwindowattribute).

## Windows validation and next steps

The Windows 11 check confirmed transparency over the real desktop and a working context menu on the rendered torso. A real mouse drag moved the avatar, which landed and saved its position. The isolated motion test also passed for a window-edge landing, a moving support, a closed support and a monitor with negative coordinates. The WPF smoke, tray self-test and isolated queue regression passed. The installed tray reported Classic visible. A second 3D launch through the installed Studio page and a real Classic drag remain to be checked.

On the GTX 1650 Ti, a 4.14 s stationary sample at the idle cap of 24 FPS measured a 41.7 ms frame interval, 16.21% of one logical CPU core, 216.7 MiB peak sampled working set, 83.5 MiB dedicated GPU memory and 30.9 MiB shared GPU memory. The busiest per-process GPU engine showed 5% in one sample. These short measurements do not establish interactive mouse-to-pose latency.

Continue with an installed Studio walkthrough for drag, window-top sitting, head petting and click-through. Verify the layout on a second physical display. Seat alignment is approximate. Hair uses bounded secondary bone motion. The initial renderer uses a simplified material path, without full MToon parity or cloth simulation.
