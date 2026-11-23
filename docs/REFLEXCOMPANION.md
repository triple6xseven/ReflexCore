# ReflexCompanion 3D

Open **Companion & Widgets** in Studio. **Preview 3D** starts the renderer and applies pending settings. **Stop** closes the renderer owned by ReflexCore. Classic can stay visible independently. Drag Classic from its labels or background when position is unlocked and click-through is off. **Reset position** returns it to its default corner.

With the 3D avatar visible, drag the body to move it. Release after a quick movement to throw it when physics is enabled. Stroke across the head for a pet reaction. Double-click the avatar to greet it. When click-through is enabled, restore the avatar’s mouse controls with **Widget → 3D mouse interaction** in the tray or turn off **Click-through** in Studio. The Classic telemetry widget remains available independently. Taskbar mode stands on the work area. Window edges and Free roam use exposed window edges within reach, or a stable magic platform when enabled.

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

Under **Companion & Widgets**, select **Edition** and apply. **Edge smoothing** offers Off, 2× and 4× MSAA. Low-power mode selects 2×. The companion uses a Windows tool window. The ReflexCore launcher owns the Studio taskbar entry. Start, stop and restart are available in Studio and the ReflexCore tray.

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

## Midnight Edition

Midnight uses the supported Lumen Original rig, expressions and hair. Its fitted top,
shorts, hem piping, belt and clasp are separate material regions cut into the
skinned geometry. The dress and shoes are removed from the derived model.
The bare and stocking editions use separate foot materials. The underlying hair
silhouette and foot topology come from the source. The outfit has no loose straps,
separate cloth solver or bespoke foot geometry.

Build the optional private models using Python, NumPy and Pillow. Run the following
commands from the repository with PowerShell. The builder verifies the source hashes
and refuses to overwrite files.

```powershell
$models = Join-Path $env:LOCALAPPDATA 'ReflexCore/companion3d'
py -3 examples/build_companion_midnight.py "$models/avatar-bare-legs.vrm" "$models/avatar-midnight.vrm"
py -3 examples/build_companion_midnight.py "$models/avatar.vrm" "$models/avatar-midnight-stockings.vrm"
```

In Studio, open **Companion & Widgets**, select **Midnight Edition** and apply.
**Midnight legs** is saved independently from **Original legs**. Select **Still**,
**Leg swing**, or **Relaxed stretch** for a seated pose. Sitting motion intensity
scales only the additional shin motion on window edges. It leaves cloud seating
and gravity independent. A missing Midnight model is reported and the loaded
avatar stays visible.

To reproduce the Godot turntable, pass the private VRM and an existing output
directory to `godot --path companion3d --script res://render_outfit.gd -- MODEL OUTPUT`.

For a 10–15 second desktop recording, set Window edges, enable the thought bubble,
choose Leg swing or Relaxed stretch, and open a blank window with its top just
above the companion. From the tray, show the companion and move the cursor
near her face. Hold on the climb, then give the seated pose a few seconds.
Brush across the head three times in short alternating horizontal strokes.
A real ReflexCore task can supply live bubble status during the recording.
With no active task the bubble can stay hidden. Capture a clean desktop without
private window content.

## Midnight Atelier

**Companion & Widgets → Edition → Midnight Atelier** selects the polished VRM.
The Midnight legs and sitting settings are shared between the two Midnight
editions. The local assets are `avatar-atelier.vrm` and
`avatar-atelier-stockings.vrm` in the companion3d runtime directory under
LocalAppData. Original and earlier Midnight variants remain selectable.

From the repository, build from the existing verified Midnight VRMs. The
builder uses Python, NumPy and Pillow, checks the input hashes, and creates
new files. Asset binaries and private captures are outside Git.

```powershell
$models = Join-Path $env:LOCALAPPDATA 'ReflexCore/companion3d'
py -3 examples/build_companion_atelier.py "$models/avatar-midnight.vrm" "$models/avatar-atelier.vrm"
py -3 examples/build_companion_atelier.py "$models/avatar-midnight-stockings.vrm" "$models/avatar-atelier-stockings.vrm"
```

The generated VRM adds a beveled chest crest, routed harness panels, corset
panels, shorts side seams and a clean cuff for the stocking variant. Its
hair mesh is reshaped and the embedded iris, catchlight, lash, blush and
hair textures are repainted. The humanoid mapping, skin weights and
existing expression morphs are retained. A single lightweight toon shader
provides soft key shading, rim and material-dependent sheen in Godot.
Atelier uses the existing surprised morph during fast-motion reactions.
The window pose uses the existing arm solve with wrists placed beside the
hips and subtly articulates the ankles as the shins swing.

The outfit uses fitted panels with inherited weights. The reference's
loose sleeves, dangling hardware, detailed toe geometry and bespoke cloth
simulation require a hand-authored garment and deformation pass. Atelier
uses rim shading and MSAA for the silhouette. The preview accepts either
VRM and produces front, side, back, three seating views, face, smile
and drag renders.

## Midnight Atelier Refined

Studio defaults to **Midnight Atelier Refined** and **Barefoot**. When the
local Refined files are unavailable, the renderer tries the corresponding
Atelier asset and then Original. The user can select an older edition at
any time. On Windows Studio uses the ReflexCore launcher icon. The renderer is a tool window. The overlay remains click-through away from the
avatar, and the tray can restore interaction if the user enables full
click-through.

Left and right presses take priority over a pending climb, cloud summon,
or autonomous walk. An existing safe perch stays in place for a short
reaction. Free Roam can step off the cloud and walk along the desktop
after a rest. The physical drag and release checks still own the mouse
gesture. Desktop capture can still suspend the overlay temporarily.

From the repository, build the private assets from the exact Atelier
exports using Python, NumPy and Pillow.

```powershell
$models = Join-Path $env:LOCALAPPDATA 'ReflexCore/companion3d'
py -3 examples/build_companion_refined.py "$models/avatar-atelier.vrm" "$models/avatar-atelier-refined.vrm"
py -3 examples/build_companion_refined.py "$models/avatar-atelier-stockings.vrm" "$models/avatar-atelier-refined-stockings.vrm"
```

The builder extends the legs, raises the hips, subtly shapes the waist,
and remaps bind matrices while preserving skin weights and morph targets.
It refines the fringe, tail, face textures and garment trim on the copied
asset. Refined adds separate window, cloud and cursor-attentive posing.
The fabric remains the fitted geometry inherited from Atelier. Loose
garment panels, detailed toe topology and a hand-keyed VRoid animation
set remain art tasks.

## Midnight Nocturne

Choose **Character → Edition → Midnight Nocturne**. Settings save and
apply to an open overlay with a short debounce. Use **Show 3D** when
opening an overlay that is stopped. Movement, Classic and Advanced
settings have their own sections.

Build the optional private files from the verified Atelier Refined VRMs.

```powershell
$models = Join-Path $env:LOCALAPPDATA 'ReflexCore/companion3d'
py -3 examples/build_companion_nocturne.py "$models/avatar-atelier-refined.vrm" "$models/avatar-nocturne.vrm"
py -3 examples/build_companion_nocturne.py "$models/avatar-atelier-refined-stockings.vrm" "$models/avatar-nocturne-stockings.vrm"
```

Nocturne reuses the humanoid rig and expressions. It has skinned ear
shells, a longer hair silhouette, shortened shorts with new hem and
strap surfaces, belt details and a satin panel. Window seating places
an arm beside each hip and extends one shin farther. Cloud sitting
uses smaller independent swings. Staying near the character triggers
a more attentive seat and reduces leg motion. Free Roam stays on a
cloud during active work or visible cursor attention. The taskbar
pose aligns to the lowest referenced mesh vertex once the feet settle.
The Godot process starts offscreen and the overlay is excluded from
the taskbar. Pin the ReflexCore application shortcut for Studio.

### Lunar Temptation

Select Lunar Temptation under Character. Generate each private avatar-lunar VRM from its matching Nocturne export with examples/build_companion_lunar.py. The new locks follow the head. Window and cloud seating use the preserved Nocturne rig.

Lunar uses distinct barefoot and stocking meshes. Build the barefoot asset with the matching
Nocturne barefoot export. Pass `--stockings` when building from the Nocturne stockings export.
In Studio, **Companion & Widgets > Advanced > Show over fullscreen apps** keeps the overlay
above borderless fullscreen apps. ReflexCore capture still pauses the overlay.
**Maximum edge smoothing** sets the MSAA ceiling. The renderer limits MSAA to 2x at
140% scale and disables it at 180% and above.

**Hover** glides toward a distant cursor and holds position during interaction.
Free Roam can make short cloud trips when the cursor is well clear and no reachable window is available.

### Alternating interactions

Each interaction starts with its classic animation and alternates on repeated occurrences during the same avatar session. The second climb leads with one hand. Thinking raises one hand and working alternates both hands. Each seat type remembers its own turn. The second visit adds an independent ankle extension when seated motion is enabled.

With sitting motion enabled, window and cloud leg crossings use the same lift, hold and release and alternate which leg goes on top. The cloud also uses a side sit and draws both knees up once every eight poses. **Dev > Cloud sit cycle** previews both leg orders, the side sit and the knee tuck in 24 seconds. Still mode keeps one pose.

### Velvet Enchantress

Choose Velvet Enchantress under Character > Edition. Its split overskirt follows the hips and upper legs. Hair, bodice and belt butterflies and cuff flowers are rigged geometry. Hover responds to horizontal velocity and vertical lift.

To prepare the private assets, run `py examples/build_companion_velvet.py SOURCE OUTPUT` once per matching Lunar legwear source. Place the results beside the Lunar files as `avatar-velvet.vrm` and `avatar-velvet-stockings.vrm`. The builder preserves the source and refuses to overwrite an existing destination.

### Velvet Bloom

Select **Velvet Bloom** in **Companion & Widgets > Character > Edition**. This additional fitted outfit has independent barefoot and stockings assets. It also supplies outfit and hair parts for **Editor**. Build the private assets with `examples/build_companion_velvet_bloom.py` from the matching Velvet Enchantress VRMs and place them beside the other local assets as `avatar-velvet-bloom.vrm` and `avatar-velvet-bloom-stockings.vrm`.

### Character Editor

In Studio, open **Companion & Widgets > Editor**. Pick an outfit, hairstyle, head, and legwear. Select **Apply and show on desktop** to save the combination as **Custom character** and preview it. Switch back to a named Edition to use its original appearance.

The library currently includes fitted outfits and hair from Midnight Nocturne, Lunar Temptation, Velvet Enchantress, Velvet Bloom and ZXC, plus Lumen and ZXC heads. Legwear uses the matching barefoot or stockings variant of the selected outfit. For stockings, choose 5, 10, 15, 20, 30 or 40 den and select dark, black, white, lilac, plum or burgundy. Density changes the visible blend of skin and fabric. Original, Midnight Edition and imported models keep their existing legwear choices. The private library keeps only referenced meshes, textures, and facial shapes needed by the widget. Godot assembles the selected parts on one shared skeleton.

After installing or rebuilding supported assets, refresh the private library with Python 3, NumPy, and Pillow.

```powershell
$models = Join-Path $env:LOCALAPPDATA 'ReflexCore/companion3d'
py examples/build_companion_wardrobe.py "$models" "$models/wardrobe"
```

Select **Reload parts** in the editor afterward. Use the current ZXC asset builder to prepare ZXC exports with part boundaries before building the library. Source VRMs, generated wardrobe data and the editable Blender file stay local.

### ZXC

Select ZXC under Character > Edition. The ZXC sculpt uses an articulated face and standalone hair fitted to the seated rig, with separate eyelids, eyes and mouth shapes. The body combines fitted Lumen anatomy and Lunar forefeet with ZXC's painted bodice and sleeves, tailored shorts and short hip panels. The face, hairstyle and outfit can be swapped independently in the Editor. Build the private anatomical surface cache with `blender -b --factory-startup --python-exit-code 1 -P examples/sculpt_zxc_body.py -- ORIGINAL_VRM LUNAR_VRM body.npz`. Pass it to `py examples/build_companion_zxc.py LUNAR_VRM FRONT BACK OUTPUT --anatomy body.npz`, optionally with `--stockings`. The original inputs, illustrations, cache and exports stay local. Both illustrations must match the ZXC atlas layout. Private runtime filenames are avatar-zxc.vrm and avatar-zxc-stockings.vrm. The face supports blink, smile, warning and surprise. The two hip panels follow the pelvis and skirt bones. A seated corrective shape guides the hem over a window ledge. Ankle rings join the shin to the remeshed forefoot. On the cloud, moving the cursor beyond the centre dead zone turns the seated silhouette gradually through the front view.

With magic enabled, Window Companion and Free Roam may travel from a cloud to a distant visible ledge with sufficient room on the current monitor. Successful remote trips alternate cloud flight and heart portal. Drag interrupts either trip. Window leg crossing begins five seconds into an uninterrupted seat with Leg swing or Relaxed stretch enabled. Still disables pose cycling.
