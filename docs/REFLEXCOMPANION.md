# ReflexCompanion 3D

Open **Companion & Widgets** in Studio. **Preview 3D** starts the renderer and applies pending settings. **Stop** closes the renderer owned by ReflexCore. Classic can stay visible independently. Drag Classic from its labels or background when position is unlocked and click-through is off. **Reset position** returns it to its default corner.

With the 3D avatar visible, drag the body to move it. Release after a quick movement to throw it when physics is enabled. Stroke across the head for a pet reaction. Double-click the avatar to greet it. When click-through is enabled, use Studio to turn it off. Taskbar mode stands on the work area. Window edges and Free roam use exposed window edges within reach, or a stable magic platform when enabled.

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

The existing tray starts one Godot process on demand and stops that exact child. Studio writes bounded settings and explicit lifecycle commands. The tray publishes real task stages, queued-job counts and current metrics using the existing activity and resource counters. The tray publishes exposed edge segments, coordinates and short-lived support IDs in a private file. It consumes WinEvent geometry changes on a bounded timer with a periodic fallback. Z-order clips edges hidden by windows above them. Caption text and native handles stay out of the bridge. Maximized windows can occlude other edges. Exclusive-sized windows and ReflexCore capture can pause the overlay. When Classic is visible, the companion speaks only about workflow.

Godot loads glTF meshes and skinning, reads VRM humanoid roles and expressions, and uses conservative local bone poses and secondary motion. Custom MToon shading, role mapping and the Windows transparent-overlay implementation were informed by the [Godot application guide](https://docs.godotengine.org/en/stable/tutorials/ui/creating_applications.html), [Godot VRM](https://github.com/V-Sekai/godot-vrm) and [Godot Clickthrough](https://github.com/KitzuGG/Godot-Clickthrough). Window surfaces use [DWM frame bounds](https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/nf-dwmapi-dwmgetwindowattribute).

## Restart and input recovery

The ReflexCore tray menu ends with **Restart** and **Exit**. Restart closes Studio and the tray, stops the supervised companion child and opens a new Studio and tray. Exit closes the same ReflexCore components. Running supervised tasks stop on shutdown. The latest Classic and 3D visibility live in a private preference file, independent of model and rendering settings. Studio saves pending widget edits on a normal close.

A drag ends on button release, even when a non-activating overlay misses the release event. The tray checks only the primary mouse-button state for a gesture the overlay already owns and returns the release token. Mode and animation reactions can change during a gesture. Click-through or fullscreen capture cancels the current grab. New visual reactions can interrupt an older emote while job execution retains the existing supervisor queue.

Cloud lobes render in the avatar's 3D scene, so the skirt and legs can cover the platform from the front. Turning off magic clears its support immediately.

Motion uses the original body footprint while the transparent viewport adds margins around it. Tilt pivots around the torso and the seated hip contact is aligned to the actual support in screen space. A fresh press replaces an older capture without waiting for the release watcher. Test with check_overlay.gd, using a scratch bridge directory containing the private avatar.

The right-click menu is rendered inside the companion viewport. Moving away dismisses it. The Windows input region follows the projected body and visible panels so the transparent area can pass clicks to the desktop. A Windows test opened and dismissed the menu with the mouse, clicked a second application's window through the transparent area, and closed the companion through the menu. The pose check measures each seated thigh and shin in body space rather than assuming the default model's orientation.

## Companion 2.0

The renderer follows the actual support window while seated. A fast move, closed edge or new overlap breaks the attachment and releases the avatar. Only nearby ledges start the approach, reach, grip, pull-up and settle sequence. The sequence uses procedural joint targets. Lumen contains no authored animation clips. Arm IK positions wrists in front of the torso during grabs and over the lap when seated. A critically damped cursor spring, bounded throw impulses and 120 Hz collision substeps cover sustained dragging, edge rebounds and swept landings.

Enable **Magic Platforms** in Studio or the character menu. Window edges and Free roam look for a reachable edge before summoning a platform. The cloud supports the seated pose, bobs slightly and can catch a nearby drop during a short grace period after a grab. A reachable exposed edge lets the character leave the cloud. Disabling magic returns the character to the taskbar when no ledge is available.

Under **Companion & Widgets**, use **Edition** for Original or Midnight Edition and **Outfit** for stockings or bare legs. Midnight derives the look in memory from the default model, adds a rig-mounted metal clasp and gem, and recolors compatible clothing materials. The runtime preserves face, rig and metadata. The source VRMs stay unchanged. This is an accessory and material variant. A new authored garment and cloth collision are still pending. **Edge smoothing** offers Off, 2× and 4× MSAA. Low-power mode selects 2×. The overlay uses the Windows tool-window style and removes its tab from the shell taskbar. Start, stop and restart are available in Studio and the ReflexCore tray.

Windows validation used a temporary native text-editor fixture and the real Godot renderer. A 27 px horizontal and 13 px vertical window move preserved the seated pose. The settled seat contact was 766 px on a 768 px edge. A larger move released the avatar into a throw reaction. An overlapping editor window hid the original edge, causing cloud summoning. Removing the cover let the avatar leave the cloud and perch again. A clothing and edition change kept the same renderer PID, and the renderer exited cleanly on its stop flag. The tray geometry check covers full and partial occlusion. The deterministic motion test covers the climb phases, unreachable edges, moving and removed supports, cloud landing, drag smoothing and five screen boundary impulses.

The installed Studio passed live Preview 3D, Restart and Stop checks via Windows UI Automation. Restart exited the old renderer and produced a new PID. The settings-file hash stayed unchanged. The default rig check validates skirt rest transforms and forward knee and wrist positions. Run it with the private default VRM as the sole user argument to Godot's check_rig.gd script.

A stationary Windows sample with both outfit variants cached recorded 24 FPS and 41.7 ms per frame at both smoothing levels. At 2× MSAA, the 4.16-second process sample measured 13.18% of one logical CPU core, 262 MiB peak working set and 134.4 MiB dedicated GPU memory. At 4×, the 3.71-second sample measured 11.04%, 243.7 MiB and 137.1 MiB respectively. The idle cap and short samples limit comparisons. These numbers do not establish interaction latency or a CPU or RAM advantage for 4×.

See [Godot's MSAA guide](https://docs.godotengine.org/en/latest/tutorials/3d/3d_antialiasing.html) and [Windows extended window styles](https://learn.microsoft.com/en-us/windows/win32/winmsg/extended-window-styles) for the rendering and shell integration.

## Earlier Windows validation

The Windows 11 check confirmed transparency over the real desktop and a working context menu on the rendered torso. A real mouse drag moved the avatar, which landed and saved its position. The isolated motion test also passed for a window-edge landing, a moving support, a closed support and a monitor with negative coordinates. The WPF smoke, tray self-test and isolated queue regression passed. The installed tray reported Classic visible. A second 3D launch through the installed Studio page and a real Classic drag remain to be checked.

On the GTX 1650 Ti, a 4.14 s stationary sample at the idle cap of 24 FPS measured a 41.7 ms frame interval, 16.21% of one logical CPU core, 216.7 MiB peak sampled working set, 83.5 MiB dedicated GPU memory and 30.9 MiB shared GPU memory. The busiest per-process GPU engine showed 5% in one sample. These short measurements do not establish interactive mouse-to-pose latency.

Continue with an installed Studio walkthrough for head petting, window focus changes and click-through. Verify the layout on a second physical display. Seat alignment is approximate. Hair uses bounded secondary bone motion. The initial renderer uses a simplified material path, without full MToon parity or cloth simulation.

The companion now faces the direction of travel. Window edges mode gives priority to the active window when its title edge leaves room for the model. Maximized windows and edges with insufficient room do not provide a seat. Free roam responds to available surfaces instead of pacing on a timer. The status bubble stays hidden in idle and briefly shows a petting reaction. A click can trigger a wave while standing. A seated click uses a small lap-and-face reaction. Clothing can change within the current session. The renderer keeps one alternate VRM in memory, so the original single-model memory sample above should not be used as the cost of the current outfit cache.

A Windows renderer check with supplied foreground bounds measured the seated contact at y=410 for an edge at y=410. The two outfit variants switched in both directions in one renderer process. The deterministic motion check covers taskbar standing, quiet roaming, foreground priority, moving supports and support removal.
