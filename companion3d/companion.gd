extends Node

const Rig = preload("res://avatar_rig.gd")
const DesktopMotion = preload("res://desktop_motion.gd")
const Cloud = preload("res://magic_cloud.gd")
const BASE_SIZE := Vector2i(344, 500)
const VIEW_MARGIN := Vector2i(80, 48)
const STATUS_SCHEMA := "reflexcore.companion.runtime.v1"
const DEFAULTS := {
	"model": "", "mode": "taskbar", "x": -1, "y": -1, "zoom": 1.0, "physics": true,
	"gravity": 900.0, "walk_speed": 58.0, "hair": true, "stockings": true,
	"midnight_stockings": false, "sit_style": "swing", "intensity": 1.0,
	"animate": true, "bubble": true, "top": true, "fullscreen_overlay": false, "clickthrough": false, "fps": 30,
	"bubble_style": "glass", "poll_ms": 400, "magic": true, "msaa": 2, "edition": "nocturne"
}
const MODE_NAMES := ["Stationary", "Taskbar Companion", "Window Companion", "Free Roam", "Follow Cursor", "Hover"]
const MODE_VALUES := ["stationary", "taskbar", "windows", "roam", "follow", "hover"]
const HIT_SEGMENTS := [
	["head","chest",24.0],["chest","hips",32.0],["hips","leftUpperLeg",24.0],["hips","rightUpperLeg",24.0],
	["leftUpperArm","leftLowerArm",12.0],["rightUpperArm","rightLowerArm",12.0],
	["leftLowerArm","leftHand",11.0],["rightLowerArm","rightHand",11.0],
	["leftUpperLeg","leftLowerLeg",15.0],["rightUpperLeg","rightLowerLeg",15.0],
	["leftLowerLeg","leftFoot",11.0],["rightLowerLeg","rightFoot",11.0]]
var bridge := ""
var options := DEFAULTS.duplicate()
var renderer := ""
var world: Node3D
var pivot: Node3D
var camera: Camera3D
var bubble: Panel
var bubble_label: Label
var bubble_style: StyleBoxFlat
var menu: PanelContainer
var menu_buttons: Dictionary = {}
var outside_menu_since := -1.0
var region_landmarks := PackedVector2Array()
var native_region := PackedVector2Array()
var next_region_at := 0.0
var rig: RefCounted
var model_file := ""
var model_error := ""
var model_attempt_at := 0.0
var cached_path := ""
var cached_mtime := 0
var cached_rig: RefCounted
var cloud: Node3D
var seat_contact_y := -1
var sole_contact_y := -1
var projected_ears := PackedVector2Array()
var portal_hearts: Array[Polygon2D] = []
var contact_ring := Line2D.new()
var seat_offset := 0.0
var body_size := BASE_SIZE
var view_margin := VIEW_MARGIN
var press_origin := Vector2.ZERO
var can_click_until := -1.0
var surface_clock := 0.0
var last_geometry := ""
var identities := {}
var model_mtime := 0
var motion := DesktopMotion.new()
var windows: Array[Rect2i] = []
var foreground := Rect2i()
var focused_edges: Array[Rect2i] = []
var status_clock := 0.0
var poll_clock := 0.0
var now := 0.0
var idle_since := 0.0
var synthetic := ""
var stage := "idle"
var source_stage := ""
var last_stage := ""
var stage_at := 0.0
var message := ""
var pending := 0
var metrics: Array[String] = []
var show_metrics := false
var paused := false
var passthrough := false
var avatar_state := "idle"
var last_reported_pose := ""
var pressed_zone := "happy"
var last_animated_touch := -99.0
var click_pose := "happy"
var click_at := -5.0
var pet_at := -5.0
var pressed := false
var gesture_token := 0
var release_check_at := 0.0
var last_drag_motion := 0.0
var release_count := 0
var contact := Vector2.ZERO
var previous_pointer := Vector2.ZERO
var gesture_direction := 0.0
var gesture_extent := 0.0
var gesture_turns := 0
var gesture_at := 0.0
var sample_us := 0
var throw_velocity := Vector2.ZERO
var head := Vector2.ZERO
var sample_ms := 0.0
var initial := true
var shown := false
var smoke_time := 0.0
var smoke_path := ""
var stopping := false
var dress_model := false
var host_seen := false
var had_motion := false
var projected_bones := {}
var last_bubble_scale := 0.0
var interaction_count := 0
var drag_count := 0

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty() or not args[0].is_absolute_path() or not DirAccess.dir_exists_absolute(args[0]):
		push_error("Pass the private ReflexCore bridge directory after --.")
		get_tree().quit(2)
		return
	bridge = args[0]
	var icon := ProjectSettings.globalize_path("res://../assets/reflexcore.ico")
	if OS.get_name()=="Windows" and FileAccess.file_exists(icon):
		DisplayServer.set_native_icon(icon)
	renderer = RenderingServer.get_current_rendering_method()
	_build_scene()
	options = _read_options()
	_load_avatar()
	if "--check" in args:
		print(JSON.stringify(_runtime_status()))
		get_tree().quit(0 if rig != null else 3)
		return
	if "--smoke" in args:
		smoke_time = 3.2
		if args.size() > 2 and args[2].is_absolute_path():
			smoke_path = args[2]
	var window := get_window()
	window.borderless = true
	window.transparent = true
	window.transparent_bg = true
	window.unfocusable = true
	window.unresizable = true
	window.close_requested.connect(_shutdown)
	_apply_options(false)
	_restore_position()
	_apply_options()
	_publish()
	_set_cursor_passthrough(true)

func _build_scene() -> void:
	world = Node3D.new()
	add_child(world)
	pivot = Node3D.new()
	world.add_child(pivot)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.near = 0.01
	camera.far = 20
	camera.position = Vector3(0, 0.94, 4)
	world.add_child(camera)
	camera.current = true
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-28, -34, 0)
	light.light_energy = 0.9
	world.add_child(light)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-15, 58, 0)
	fill.light_color = Color("#d7eeff")
	fill.light_energy = 0.55
	world.add_child(fill)
	var env_node := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_CLEAR_COLOR
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("#e8f1ff")
	environment.ambient_light_energy = 0.68
	env_node.environment = environment
	world.add_child(env_node)

	var layer := CanvasLayer.new()
	add_child(layer)
	for index in 9:
		var heart := Polygon2D.new()
		var vertices := PackedVector2Array()
		for sample in 32:
			var t := TAU*sample/32.0
			vertices.append(Vector2(16*pow(sin(t),3),-13*cos(t)+5*cos(2*t)+2*cos(3*t)+cos(4*t)))
		heart.polygon=vertices
		heart.visible=false
		layer.add_child(heart)
		portal_hearts.append(heart)
	layer.add_child(contact_ring)
	contact_ring.visible=false
	contact_ring.width=2.0
	contact_ring.antialiased=true
	cloud = Cloud.new()
	world.add_child(cloud)
	bubble = Panel.new()
	bubble.size = Vector2(250, 40)
	bubble.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bubble_style = StyleBoxFlat.new()
	bubble_style.bg_color = Color("#182238ed")
	bubble_style.border_color = Color("#80e5dd")
	bubble_style.set_border_width_all(1)
	bubble_style.set_corner_radius_all(13)
	bubble.add_theme_stylebox_override("panel",bubble_style)
	layer.add_child(bubble)
	bubble_label = Label.new()
	bubble_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bubble_label.offset_left = 12
	bubble_label.offset_right = -12
	bubble_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bubble_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bubble_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bubble_label.max_lines_visible = 2
	bubble_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	bubble_label.add_theme_font_size_override("font_size", 14)
	bubble_label.add_theme_color_override("font_color", Color("#f4f9ff"))
	bubble_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bubble.add_child(bubble_label)
	# Keep the menu on the overlay canvas. A native popup can capture clicks
	# from the non-activating owner and never give them back.
	menu=PanelContainer.new()
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color=Color("#192336")
	panel_style.border_color=Color("#667c97")
	panel_style.set_border_width_all(1)
	panel_style.set_corner_radius_all(8)
	panel_style.content_margin_left=6
	panel_style.content_margin_right=6
	panel_style.content_margin_top=6
	panel_style.content_margin_bottom=6
	menu.add_theme_stylebox_override("panel",panel_style)
	layer.add_child(menu)
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation",2)
	menu.add_child(rows)
	for i in MODE_NAMES.size():
		_add_menu_button(rows,i,false)
	rows.add_child(HSeparator.new())
	for id in [10,11,12]:
		_add_menu_button(rows,id,true)
	rows.add_child(HSeparator.new())
	_add_menu_button(rows,20,false)
	menu.hide()

func _add_menu_button(rows: VBoxContainer, id: int, check: bool) -> void:
	var button := CheckButton.new() if check else Button.new()
	button.custom_minimum_size=Vector2(186,26)
	button.alignment=HORIZONTAL_ALIGNMENT_LEFT
	button.focus_mode=Control.FOCUS_NONE
	button.pressed.connect(_menu_action.bind(id))
	rows.add_child(button)
	menu_buttons[id]=button

func _show_menu(anchor: Vector2) -> void:
	for i in MODE_NAMES.size():
		menu_buttons[i].text=("●  " if MODE_VALUES[i]==options.mode else "    ")+MODE_NAMES[i]
	for entry in [[10,"Show status bubble",options.bubble],[11,"Stockings",options[_stocking_key()]],[12,"Magic Platforms",options.magic]]:
		var button: CheckButton=menu_buttons[entry[0]]
		button.text=entry[1]
		button.set_pressed_no_signal(entry[2])
	menu_buttons[20].text="Close ReflexCompanion"
	menu.reset_size()
	var limit := Vector2(get_window().size)-menu.get_combined_minimum_size()
	menu.position=anchor.clamp(Vector2.ZERO,limit.max(Vector2.ZERO))
	outside_menu_since=-1
	menu.show()
	next_region_at=0
	_update_window_region()
	_set_cursor_passthrough(false)
	_publish()

func _hide_menu() -> void:
	menu.hide()
	outside_menu_since=-1
	can_click_until=-1
	next_region_at=0.0
	_update_window_region()
	_publish()

func _read_json(path: String, limit: int) -> Dictionary:
	var file := FileAccess.open(path,FileAccess.READ)
	if file == null or file.get_length() > limit:
		return {}
	var value: Variant = JSON.parse_string(file.get_as_text())
	return value if value is Dictionary else {}

func _read_options() -> Dictionary:
	var file := _read_json(bridge.path_join("settings.json"),16384)
	var next := DEFAULTS.duplicate()
	for key in DEFAULTS:
		var value: Variant = file.get(key)
		if typeof(value)==typeof(DEFAULTS[key]) or typeof(value) in [TYPE_FLOAT,TYPE_INT] and typeof(DEFAULTS[key]) in [TYPE_FLOAT,TYPE_INT]:
			next[key] = value
	if not next.mode in MODE_VALUES:
		next.mode = "taskbar"
	next.zoom = clampf(float(next.zoom),0.65,2.0)
	next.gravity = clampf(float(next.gravity),120,2400)
	next.walk_speed = clampf(float(next.walk_speed),10,280)
	next.fps = clampi(int(next.fps),15,60)
	next.msaa=clampi(int(next.msaa),0,2)
	if next.edition not in ["original","midnight","atelier","atelier_refined","nocturne","lunar","velvet","zxc"]:next.edition="nocturne"
	if next.sit_style not in ["still","swing","relaxed"]:next.sit_style="swing"
	next.intensity=clampf(float(next.intensity),0.0,1.0)
	next.poll_ms = clampi(int(next.poll_ms),200,2500)
	if next.model is String and (not next.model.is_absolute_path() or next.model.length()>3000):
		next.model = ""
	return next

func _stocking_key() -> String:
	return "midnight_stockings" if options.edition in ["midnight","atelier","atelier_refined","nocturne","lunar","velvet","zxc"] and str(options.model).is_empty() else "stockings"

func _pick_model() -> String:
	var desired: String = options.model
	dress_model=false
	if desired.is_empty():
		if options.edition in ["midnight","atelier","atelier_refined","nocturne","lunar","velvet","zxc"]:
			var suffix := "-stockings.vrm" if options.midnight_stockings else ".vrm"
			var prefixes := [str(options.edition).replace("_","-")]
			if options.edition=="nocturne":
				prefixes.append("atelier-refined")
			if options.edition in ["nocturne","atelier_refined"]:
				prefixes.append("atelier")
			for edition in prefixes:
				var prefix := "avatar-"+String(edition)
				var asset := bridge.path_join(prefix+suffix)
				if FileAccess.file_exists(asset):
					dress_model=FileAccess.file_exists(bridge.path_join(prefix+".vrm")) 						and FileAccess.file_exists(bridge.path_join(prefix+"-stockings.vrm"))
					return asset
		for extension in ["vrm","glb"]:
			var variant := bridge.path_join("avatar-bare-legs."+extension)
			if not options.stockings and FileAccess.file_exists(variant):
				dress_model=true
				return variant
			var base := bridge.path_join("avatar."+extension)
			if FileAccess.file_exists(base):
				dress_model=FileAccess.file_exists(variant)
				return base
		return ""
	if desired.get_extension().to_lower() not in ["vrm","glb"]:
		return ""
	var alternative := desired.get_basename()+"-bare-legs."+desired.get_extension()
	dress_model=FileAccess.file_exists(alternative)
	return alternative if dress_model and not options.stockings else desired

func _load_avatar() -> void:
	var path := _pick_model()
	if path.is_empty():
		model_error = "model_missing" if rig == null else ""
		return
	var touched := FileAccess.get_modified_time(path)
	if path==model_file and touched==model_mtime:
		return
	var cache_hit := path==cached_path and touched==cached_mtime
	if not cache_hit and (now < model_attempt_at or menu.visible or pressed):
		return
	if not cache_hit:
		model_attempt_at=now+3.0
	var previous_file := model_file
	var previous_mtime := model_mtime
	var candidate = cached_rig if cache_hit else Rig.new()
	if not cache_hit and not candidate.load_file(path):
		model_error="edition_asset_missing" if not FileAccess.file_exists(path) else candidate.error
		return
	model_file=path
	model_mtime=touched
	# Import first. An invalid replacement never removes the working character.
	if rig!=null and is_instance_valid(rig.scene):
		pivot.remove_child(rig.scene)
		if candidate!=cached_rig and cached_rig!=null:
			cached_rig.free_scene()
		cached_rig=rig
		cached_path=previous_file
		cached_mtime=previous_mtime
	rig=candidate
	pivot.add_child(rig.scene)
	projected_bones.clear()
	var size_factor:=1.65/float(rig.height)
	rig.scene.scale=Vector3.ONE*size_factor
	rig.scene.position.y=-float(rig.bottom)*size_factor
	rig.scene.rotation.y=PI if rig.legacy else 0
	model_error=""
	_camera_layout()

func _apply_options(resize_window := true) -> void:
	var window := get_window()
	var old_body := body_size
	body_size=Vector2i(Vector2(BASE_SIZE)*float(options.zoom))
	# Keep tilt clearance without scaling the transparent border at high zoom.
	view_margin=Vector2i(Vector2(VIEW_MARGIN)*minf(1.0,float(options.zoom)))
	var desired := body_size+view_margin*2
	if resize_window and window.size!=desired:
		window.size=desired
		if not initial:
			motion.position+=Vector2(float(old_body.x-body_size.x)/2,float(old_body.y-body_size.y))
	window.always_on_top=bool(options.top)
	# A doubled window has four times the pixels. Keep the MSAA sample budget bounded.
	var effective_msaa := int(options.msaa)
	if float(options.zoom)>=1.40:
		effective_msaa=mini(effective_msaa,1)
	if float(options.zoom)>=1.80:
		effective_msaa=0
	window.msaa_3d=effective_msaa as Viewport.MSAA
	bubble_style.bg_color=Color("#101b27e9") if options.bubble_style=="minimal" else Color("#182238ed")
	bubble_style.set_corner_radius_all(5 if options.bubble_style=="minimal" else 13)
	_camera_layout()

func _camera_layout() -> void:
	var h := float(get_window().size.y)
	if h < 170:
		return
	var horizontal_pad := 113.0 * float(options.zoom)
	camera.size=1.65*h/(body_size.y-horizontal_pad)
	camera.position.y=(0.5-(39.0*float(options.zoom)+view_margin.y)/h)*camera.size

func _screen_rect() -> Rect2i:
	var screen := get_window().current_screen
	if screen<0 or screen>=DisplayServer.get_screen_count():
		screen=DisplayServer.get_primary_screen()
	var rect := DisplayServer.screen_get_usable_rect(screen)
	return rect if rect.has_area() else Rect2i(Vector2i.ZERO,Vector2i(1920,1080))

func _restore_position(reset := false) -> void:
	var area := _screen_rect()
	var size := body_size
	var fallback := Vector2i(area.end.x-size.x-18, area.end.y-size.y+20)
	var saved := {} if reset else _read_json(bridge.path_join("position.json"),1024)
	var x := int(options.x)
	var y := int(options.y)
	if x==-1 and y==-1:
		x=int(saved.get("x",fallback.x))
		y=int(saved.get("y",fallback.y))
	var desktop := Rect2i()
	for i in DisplayServer.get_screen_count():
		var rect := DisplayServer.screen_get_usable_rect(i)
		if rect.has_point(Vector2i(x+size.x/2,y+size.y/2)):
			desktop=rect
			break
	if not desktop.has_area():
		x=fallback.x
		y=fallback.y
	motion.place(Vector2(x,y))
	get_window().position=Vector2i(motion.position)-view_margin
	initial=false

func _poll() -> void:
	if FileAccess.file_exists(bridge.path_join("stop.flag")):
		_shutdown()
		return
	var revised := _read_options()
	if revised!=options:
		var pos_changed: bool = revised.x!=options.x or revised.y!=options.y
		options=revised
		_apply_options()
		if pos_changed:
			_restore_position()
	var reset := bridge.path_join("reset-position.flag")
	if FileAccess.file_exists(reset):
		DirAccess.remove_absolute(reset)
		_restore_position(true)
		_write_position()
	_load_avatar()
	var live := _read_json(bridge.path_join("live.json"),32*1024)
	var timestamp := float(live.get("at_unix_ms",0))
	if timestamp>0 and absf(Time.get_unix_time_from_system()*1000.0-timestamp)>6000.0:
		live={}
	if live.is_empty():
		if host_seen:
			stage="idle"
			message=""
			metrics.clear()
			pending=0
			paused=false
		return
	host_seen=true
	paused=live.get("paused",false)==true and smoke_time==0.0
	var recent_stage := str(live.get("stage","idle")).to_lower()
	var new_stage := _normal_stage(recent_stage)
	if new_stage!=source_stage:
		source_stage=new_stage
		stage_at=now
	stage=new_stage
	message=str(live.get("message","")).replace("\n"," ").left(110)
	pending=clampi(int(live.get("pending",0)),0,9999)
	metrics.clear()
	var raw_metrics: Variant = live.get("metrics",[])
	if raw_metrics is String:
		raw_metrics=[raw_metrics]
	if raw_metrics is Array:
		for metric in raw_metrics.slice(0,4):
			if metric is String:
				metrics.append(metric.replace("\n"," ").left(110))
	show_metrics=live.get("show_metrics",false)==true and live.get("classic_visible",false)!=true
	# Older hosts publish rectangles only. Current hosts publish exposed edges separately.
	if not FileAccess.file_exists(bridge.path_join("surfaces.json")):
		var focused: Variant = live.get("foreground",[])
		foreground=Rect2i(int(focused[0]),int(focused[1]),int(focused[2]),int(focused[3])) if focused is Array and focused.size()==4 else Rect2i()
		_set_surfaces(live.get("bounds",[]))

func _poll_surfaces(dt: float) -> void:
	surface_clock+=dt
	if surface_clock<0.038:
		return
	surface_clock=0.0
	var file := FileAccess.open(bridge.path_join("surfaces.json"),FileAccess.READ)
	if file==null or file.get_length()>16*1024:
		return
	var raw := file.get_as_text()
	if raw==last_geometry:
		return
	var value: Variant = JSON.parse_string(raw)
	if not value is Dictionary:
		return
	last_geometry=raw
	foreground=Rect2i()
	_set_surfaces(value.get("edges",[]))

func _set_surfaces(rows: Variant) -> void:
	windows.clear()
	identities.clear()
	focused_edges.clear()
	if not rows is Array:
		return
	for row in rows.slice(0,48):
		if not row is Array or not row.size() in [4,8]:
			continue
		var edge := Rect2i(int(row[0]),int(row[1]),clampi(int(row[2]),0,20000),clampi(int(row[3]),0,20000))
		if not edge.has_area():
			continue
		windows.append(edge)
		if row.size()==8:
			identities[edge]=[int(row[4]),int(row[5]),int(row[6])]
			if row[7]==1:
				focused_edges.append(edge)

func _normal_stage(text: String) -> String:
	if "warn" in text or "fail" in text or "error" in text or "stop" in text:
		return "warning"
	if "verif" in text or "success" in text or "complete" in text:
		return "success"
	if "think" in text or "plan" in text or "decid" in text:
		return "thinking"
	if "observ" in text or "captur" in text or "watch" in text:
		return "observing"
	if "work" in text or "run" in text or "execut" in text:
		return "working"
	return "idle"

func _process(delta: float) -> void:
	if bridge.is_empty() or stopping:
		return
	now+=minf(delta,0.12)
	_poll_surfaces(delta)
	poll_clock-=delta
	status_clock+=delta
	if poll_clock<=0:
		_poll()
		poll_clock=float(options.poll_ms)/1000.0
	if stopping:
		return
	var window := get_window()
	if paused:
		if menu.visible:_hide_menu()
		if pressed:_release(false)
		if shown:
			window.position=Vector2i(-32000,-32000)
		shown=false
		Engine.max_fps=10
		if status_clock>=1.8:
			_publish()
		return
	var dt := clampf(delta,0.001,0.05)
	sample_ms=lerpf(sample_ms,1000.0*delta,0.09)
	var pointer := DisplayServer.mouse_get_position()
	var local := Vector2(pointer-window.position)
	_check_drag_release()
	if pressed:_maybe_grab(Vector2(pointer))
	var area := _screen_rect()
	if motion.held:
		var wanted := Vector2(pointer)-contact
		# Follow the cursor between displays while leaving all applications untouched.
		motion.drag_to(wanted,throw_velocity,dt)
	var focus := foreground
	var focus_distance := INF
	for edge in focused_edges:
		var distance := absf(float(edge.get_center().x)-motion.position.x-window.size.x*0.5)
		if distance<focus_distance:
			focus=edge
			focus_distance=distance
	var physical: String = motion.update(dt,now,area,body_size,pointer,options,windows,focus,identities,stage in ["working","thinking","observing"] or _near_model(local,42))
	if had_motion and not motion.falling and not motion.held:
		_write_position()
	had_motion=motion.falling or motion.held
	avatar_state=_choose_pose(physical,local)
	var actual:=Vector2i(motion.position)-view_margin
	if rig!=null:
		var moving := physical in ["walk","run"]
		var hovering := physical=="hover"
		var cloud_pose: bool=motion.cloud_seated
		var rising := physical=="stand_up"
		var seated: bool=not rising and (physical in ["sit","settle","cloud_sit"] or cloud_pose)
		var yaw := signf(motion.velocity.x)*PI*0.46 if moving else clampf(motion.velocity.x/160.0,-.78,.78) if hovering else -0.77 if cloud_pose else -0.64 if seated or rising else 0.0
		pivot.rotation.y=lerp_angle(pivot.rotation.y,yaw,minf(10*dt,1))
		if physical=="dragged" and bool(options.animate):
			pivot.rotation.x=lerpf(pivot.rotation.x,clampf(motion.velocity.y/4500.0,-0.19,0.19),1-exp(-9*dt))
		else:
			pivot.rotation.x=lerpf(pivot.rotation.x,0,1-exp(-12*dt))
		pivot.rotation.z=lerpf(pivot.rotation.z,motion.angle,1-exp(-11*dt))
		# Lean around the body, not around the feet at the scene origin.
		var torso_center := Vector3(0,0.86,0)
		pivot.scale=Vector3.ONE*maxf(.015,motion.portal_scale)
		pivot.position=torso_center-pivot.basis*torso_center
		var gaze := (local-head)/145.0
		if not _near_model(local,52):
			gaze=Vector2(sin(now*0.48)*0.32,sin(now*0.28)*0.13)
		if stage=="warning" and now>=motion.operator_until:
			gaze.y=-0.55
		var touch_time := maxf(click_at,pet_at)
		var new_touch := touch_time != last_animated_touch
		last_animated_touch = touch_time
		rig.animate(dt,now,avatar_state,gaze,motion.velocity,bool(options.hair),bool(options.animate),seated,motion.impact,cloud_pose,_is_midnight_loaded() and physical=="sit",str(options.sit_style),float(options.intensity),new_touch)
		var edge := float(motion.support.position.y) if motion.seated else motion.position.y+body_size.y*DesktopMotion.SEAT_RATIO
		var hip_pad := 11*float(options.zoom)
		var hip_y := camera.unproject_position(rig.world_bone("hips")).y+hip_pad
		var target_offset := (hip_y-(edge-actual.y))*camera.size/window.size.y if seated else 0.0
		var contact_y := -1.0
		var floor_pose := not pressed and not motion.supported and physical in ["walk","run"]
		var collision_floor := area.end.y-3-(body_size.y-25.0*body_size.y/500.0)
		floor_pose=floor_pose and motion.position.y>=collision_floor-4
		if (options.mode=="taskbar" and physical in ["idle","sleepy"] and not pressed) or floor_pose:
			contact_y=camera.unproject_position(rig.scene.to_global(Vector3(0,rig.sole_y,0))).y
			target_offset=(contact_y-(area.end.y-1-actual.y))*camera.size/window.size.y
		if hovering:
			target_offset=.035*sin(now*3.0)
		seat_offset=lerpf(seat_offset,target_offset,1-exp(-14*dt))
		sole_contact_y=roundi(actual.y+contact_y-seat_offset*window.size.y/camera.size) if contact_y>=0.0 else -1
		pivot.position.y+=seat_offset
		seat_contact_y=roundi(actual.y+camera.unproject_position(rig.world_bone("hips")).y+hip_pad) if seated else -1
		for role in rig.roles:
			projected_bones[role]=camera.unproject_position(rig.world_bone(role))
		head=projected_bones["head"]
		projected_ears.clear()
		for ear in rig.ear_anchors():
			projected_ears.append(camera.unproject_position(ear))
	for i in portal_hearts.size():
		var heart := portal_hearts[i]
		heart.visible=physical=="portal"
		if heart.visible:
			var burst := sin(PI*minf(motion.portal_time/1.04,1))
			var orbit := Vector2.from_angle(TAU*i/portal_hearts.size()+motion.portal_time*1.7)
			heart.position=projected_bones.get("chest",head)+orbit*Vector2(52,68)*burst*float(options.zoom)
			heart.scale=Vector2.ONE*(.18+.29*burst)*float(options.zoom)
			heart.color=Color(.99,.44,.79,burst)
	_update_contact_effect()
	cloud.show_at(camera,Vector2(motion.cloud_x,motion.cloud_edge if not motion.cloud_seated else motion.position.y+body_size.y*DesktopMotion.SEAT_RATIO)-Vector2(actual),float(options.zoom),motion.cloud_alpha*motion.portal_scale,now,window.size.y)
	if actual!=window.position:
		window.position=actual
	_update_bubble()
	shown=true
	_update_window_region()
	_track_input(Vector2(pointer-window.position),dt)
	var interactive := menu.visible or pressed or motion.falling or avatar_state in ["walk","run","landing","petted","approach","reach","grip","pull_up","settle","stand_up","hover","cloud_fly","cloud_summon"] or _near_model(local,25)
	var frame_limit := clampi(int(options.fps),15,60)
	var seat_transition: bool = physical in ["settle","pull_up","cloud_summon"] or (rig!=null and (physical in ["sit","cloud_sit"] and rig.stance<.99))
	var changing_cloud_pose: bool = rig!=null and motion.cloud_seated and options.sit_style!="still" and options.animate and (fmod(rig.cloud_clock,4.8)<1.6 or fmod(rig.cloud_clock,4.8)>3.08)
	var changing_window_pose: bool = rig!=null and rig.crossed>0 and rig.crossed<1
	if physical in ["cloud_fly","portal"] or seat_transition or changing_cloud_pose or changing_window_pose:
		interactive=true
		frame_limit=maxi(frame_limit,48)
	interactive=interactive or physical=="portal"
	Engine.max_fps=frame_limit if interactive else mini(24,frame_limit)
	if status_clock>=1.8 or avatar_state!=last_reported_pose:
		last_reported_pose=avatar_state
		_publish()
	if smoke_time>0 and now>=smoke_time:
		if not smoke_path.is_empty():
			var image := get_viewport().get_texture().get_image()
			if image!=null:
				image.save_png(smoke_path)
		print(JSON.stringify(_runtime_status()))
		_shutdown()

func _update_contact_effect() -> void:
	var age: float=now-motion.impact_at
	var show_ring: bool=bool(options.animate) and age>=0 and age<0.34 and motion.impact_speed>155 and not motion.held
	contact_ring.visible=show_ring and projected_bones.has("leftFoot")
	if not contact_ring.visible:
		return
	var at: Vector2=(projected_bones.leftFoot+projected_bones.rightFoot)*0.5
	var axis := Vector2.RIGHT
	if "top" in motion.impact:
		at=head-Vector2(0,28)*float(options.zoom)
	elif motion.impact in ["left","right"]:
		var direction := -1 if motion.impact=="left" else 1
		at=projected_bones.chest+Vector2(direction*24,0)*float(options.zoom)
		axis=Vector2.DOWN
	var t := age/0.34
	var radius := (6+20*t)*clampf(motion.impact_speed/600.0,0.55,1.35)*float(options.zoom)
	var points := PackedVector2Array()
	for i in 25:
		var phase := i*TAU/24
		points.append(at+radius*(axis*cos(phase)+axis.orthogonal()*sin(phase)*0.36))
	contact_ring.points=points
	contact_ring.default_color=Color(0.73,0.85,1.0,0.8*(1-t))

func _choose_pose(physical: String, local: Vector2) -> String:
	if physical in ["dragged","thrown","falling","hard_collision"]:
		return physical
	if physical in ["run","walk","approach","reach","grip","pull_up","settle","stand_up","hover","cloud_fly","look_around","cloud_summon","landing","recovering","soft_collision"]:
		return physical
	if now-pet_at<1.6:
		return "petted"
	if now-click_at<1.65:
		return click_pose
	if stage=="success" and now-stage_at<4.2:
		return "happy"
	if rig!=null and rig.refined and physical in ["sit","cloud_sit"] and _near_model(local,36):
		return "attentive"
	if now<motion.operator_until:
		return physical
	if stage=="warning" and now-stage_at<9.0:
		return "warning"
	if stage in ["thinking","working"]:
		return stage
	if stage=="observing" or _near_model(local,25):
		return "curious"
	return physical

func _update_bubble() -> void:
	var window_size := Vector2(get_window().size)
	var text := _bubble_message()
	var visible := (bool(options.bubble) and not text.is_empty()) or rig==null
	bubble.visible=visible
	if not visible:
		return
	var scale_value := float(options.zoom)
	if scale_value!=last_bubble_scale:
		last_bubble_scale=scale_value
		bubble.size=Vector2(250,40)*scale_value
		bubble_label.add_theme_font_size_override("font_size",clampi(roundi(13*scale_value),10,26))
	var anchor := head if rig!=null else window_size*0.5
	bubble.position=Vector2(clampf(anchor.x-bubble.size.x/2,4,window_size.x-bubble.size.x-4),maxf(4,anchor.y-bubble.size.y-50*scale_value))
	if text!=bubble_label.text:
		bubble_label.text=text
		bubble.modulate.a=0.66
	bubble.modulate.a=move_toward(bubble.modulate.a,1,0.08)

func _bubble_message() -> String:
	if rig==null:
		return "Choose a rigged VRM or GLB in Studio."
	if now-pet_at<1.6:
		return "Ã¢Å“Â¦"
	if stage=="idle" and pending==0:
		return ""
	if stage=="success" and pending==0 and now-stage_at>4.2:
		return ""
	var slot := int(now/5)%3
	if slot==2 and show_metrics and not metrics.is_empty():
		return metrics[int(now/15.0)%metrics.size()]
	if slot==1 and pending>0:
		return ("%d task waiting" if pending==1 else "%d tasks waiting")%pending
	if not message.is_empty() and stage!="idle":
		return message
	return {"thinking":"ThinkingÃ¢â‚¬Â¦","working":"WorkingÃ¢â‚¬Â¦","observing":"Observing",
		"success":"Task complete","warning":"Task needs attention"}.get(stage,"")

func _head_circle(local: Vector2, padding: float) -> bool:
	if rig==null:
		return false
	var radius := 33.0 * float(options.zoom) + padding
	return local.distance_squared_to(head+Vector2(0,-2.0*float(options.zoom)))<radius*radius

func _near_model(local: Vector2,padding: float) -> bool:
	if rig==null:
		return bubble.get_rect().has_point(local)
	if _head_circle(local,padding):
		return true
	for pair in HIT_SEGMENTS:
		if not projected_bones.has(pair[0]) or not projected_bones.has(pair[1]):
			continue
		var a:Vector2=projected_bones[pair[0]]
		var b:Vector2=projected_bones[pair[1]]
		if local.distance_to(Geometry2D.get_closest_point_to_segment(local,a,b))<(float(pair[2])*float(options.zoom)+padding):
			return true
	return false

func _pointer_on_character(local: Vector2) -> bool:
	for ear in projected_ears:
		if local.distance_to(ear)<24*float(options.zoom):
			return true
	if _near_model(local,12):
		return true
	var zoom := float(options.zoom)
	if projected_bones.has("hips"):
		var hips: Vector2=projected_bones["hips"]
		var outfit := (local-hips-Vector2(0,14*zoom))/Vector2(62,47)/zoom
		if outfit.length_squared()<1.0:
			return true
	if motion.cloud_seated and cloud.visible:
		var seat := Vector2(motion.cloud_x,motion.position.y+body_size.y*DesktopMotion.SEAT_RATIO)-Vector2(get_window().position)
		return ((local-seat-Vector2(0,19*zoom))/Vector2(77,23)/zoom).length_squared()<1.0
	return false

func _track_input(local: Vector2, dt: float) -> void:
	# Leave the rendered pixels intact while letting clicks outside projected hit
	# zones reach the desktop. No polling of other applications' input.
	if menu.visible:
		var over_menu := menu.get_rect().has_point(local)
		if over_menu:
			outside_menu_since=-1
		elif outside_menu_since<0:
			outside_menu_since=now
		if bool(options.clickthrough) or (outside_menu_since>=0 and now-outside_menu_since>0.20):
			_hide_menu()
		_set_cursor_passthrough(bool(options.clickthrough) or not (over_menu or _pointer_on_character(local)))
		return
	var can_click := _pointer_on_character(local)
	if can_click:can_click_until=now+0.14
	_set_cursor_passthrough(bool(options.clickthrough) or not (pressed or can_click or now<can_click_until))
	if pressed:
		var global := Vector2(DisplayServer.mouse_get_position())
		_sample_throw(global)
		_maybe_grab(global)
		return
	if bool(options.clickthrough) or not _head_circle(local,0):
		gesture_turns=0
		gesture_extent=0
		gesture_direction=0
		previous_pointer=local
		return
	if now-gesture_at>0.85:
		gesture_turns=0
		gesture_extent=0
		gesture_direction=0
		gesture_at=now
	var travel := local-previous_pointer
	previous_pointer=local
	if absf(travel.x)>3 and absf(travel.y)<17:
		var direction := signf(travel.x)
		if direction!=gesture_direction and gesture_extent>=10:
			gesture_turns+=1
			gesture_extent=0
		gesture_extent+=absf(travel.x)
		gesture_direction=direction
		if gesture_turns>=3:
			pet_at=now
			click_at=-5.0
			gesture_turns=0

func _update_window_region() -> void:
	if OS.get_name()!="Windows" or now<next_region_at or projected_bones.is_empty():
		return
	next_region_at=now+0.042
	var zoom := float(options.zoom)
	var centers := PackedVector2Array()
	var radii := PackedVector2Array()
	for role in ["head","chest","hips","leftUpperArm","rightUpperArm","leftLowerArm","rightLowerArm","leftHand","rightHand","leftLowerLeg","rightLowerLeg","leftFoot","rightFoot"]:
		if not projected_bones.has(role):
			continue
		var center: Vector2=projected_bones[role]
		var radius := Vector2(68,73) if role=="head" else Vector2(89,74) if role=="hips" else Vector2(47,53) if role.ends_with("Foot") else Vector2(46,47)
		centers.append(center)
		radii.append(radius*zoom)
	for ear in projected_ears:
		centers.append(ear)
		radii.append(Vector2.ONE*31*zoom)
	var rects: Array[Rect2] = []
	if bubble.visible:
		rects.append(bubble.get_rect().grow(2))
	if motion.portal_time>0:
		var center: Vector2=projected_bones.get("chest",head)
		var radius := Vector2(70,84)*zoom
		rects.append(Rect2(center-radius,2*radius))
	if cloud.visible:
		var base := Vector2(motion.cloud_x,motion.position.y+body_size.y*DesktopMotion.SEAT_RATIO if motion.cloud_seated else motion.cloud_edge)-Vector2(get_window().position)
		rects.append(Rect2(base-Vector2(106,35)*zoom,Vector2(212,94)*zoom))
	if menu.visible:
		rects.append(menu.get_rect().grow(1))

	# Avoid replacing the native window region for subpixel idle motion. Compare
	# against the last applied region so slow cumulative movement still updates.
	var landmarks := centers.duplicate()
	landmarks.append(Vector2(zoom*100,centers.size()))
	for rect in rects:
		landmarks.append(rect.position)
		landmarks.append(rect.end)
	var stable := landmarks.size()==region_landmarks.size()
	if stable:
		for i in landmarks.size():
			if landmarks[i].distance_squared_to(region_landmarks[i])>9:
				stable=false
				break
	if stable:
		return
	region_landmarks=landmarks
	var points := PackedVector2Array()
	for n in centers.size():
		for i in 8:
			points.append(centers[n]+Vector2.from_angle(i*TAU/8)*(radii[n]+Vector2(4,4)))
	var outline := Geometry2D.convex_hull(points)
	for rect in rects:
		outline=_add_region_rect(outline,rect.grow(4))
	if outline!=native_region:
		native_region=outline
		get_window().mouse_passthrough_polygon=native_region

func _add_region_rect(outline: PackedVector2Array, rect: Rect2) -> PackedVector2Array:
	var corners := PackedVector2Array([rect.position,Vector2(rect.end.x,rect.position.y),rect.end,Vector2(rect.position.x,rect.end.y)])
	var merged := Geometry2D.merge_polygons(outline,corners)
	return merged[0] if merged.size()==1 else Geometry2D.convex_hull(outline+corners)

func _set_cursor_passthrough(value: bool) -> void:
	if value==passthrough:
		return
	passthrough=value
	get_window().mouse_passthrough=value

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and pressed:
		var movement := event as InputEventMouseMotion
		_maybe_grab(Vector2(get_window().position)+movement.position)
	if not event is InputEventMouseButton:
		return
	var mouse := event as InputEventMouseButton
	var position := Vector2(get_window().position)+mouse.position
	if menu.visible:
		if mouse.pressed and mouse.button_index==MOUSE_BUTTON_LEFT and not menu.get_rect().has_point(mouse.position):
			_hide_menu()
		elif mouse.pressed and mouse.button_index==MOUSE_BUTTON_RIGHT:
			_hide_menu()
			_set_cursor_passthrough(not _pointer_on_character(mouse.position))
			return
		else:
			return
	if mouse.button_index==MOUSE_BUTTON_LEFT and not mouse.pressed and pressed:
		_release()
		return
	if bool(options.clickthrough):
		return
	if mouse.button_index==MOUSE_BUTTON_RIGHT and mouse.pressed and (_pointer_on_character(mouse.position) or now<can_click_until):
		if pressed:_release(false)
		motion.interrupt(now,bool(options.physics))
		_show_menu(mouse.position)
		return
	if mouse.button_index!=MOUSE_BUTTON_LEFT:
		return
	if mouse.pressed and (_pointer_on_character(mouse.position) or pressed or now<can_click_until):
		# A fresh press supersedes a stale capture even if the prior mouse-up was lost.
		if pressed:_release(false)
		pressed=true
		pressed_zone=_click_pose_at(mouse.position)
		motion.interrupt(now,bool(options.physics))
		press_origin=position
		last_drag_motion=now
		release_check_at=now+0.12
		gesture_token=randi_range(1,2147483600)
		var marker := FileAccess.open(bridge.path_join("drag-active.txt"),FileAccess.WRITE)
		if marker!=null:
			marker.store_string(str(gesture_token))
			marker.close()
		interaction_count+=1
		previous_pointer=position
		sample_us=Time.get_ticks_usec()
		throw_velocity=Vector2.ZERO

func _check_drag_release() -> void:
	if not pressed:
		return
	if bool(options.clickthrough) or now-last_drag_motion>12.0:
		_release(false)
		return
	if now<release_check_at:
		return
	release_check_at=now+0.055
	var marker := FileAccess.open(bridge.path_join("drag-release.txt"),FileAccess.READ)
	if marker!=null and marker.get_length()<=24 and marker.get_as_text().to_int()==gesture_token:
		_release()
	elif not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_release()

func _click_pose_at(point: Vector2) -> String:
	for foot in ["leftFoot","rightFoot"]:
		if projected_bones.has(foot) and point.distance_to(projected_bones[foot])<26*float(options.zoom):
			return "tickled"
	if point.distance_to(head)<40*float(options.zoom):
		return "face_smile"
	return "happy"

func _sample_throw(point: Vector2) -> void:
	var tick := Time.get_ticks_usec()
	var elapsed := (tick-sample_us)/1000000.0
	if elapsed<0.004 or previous_pointer.distance_squared_to(point)<1:
		return
	var observed := ((point-previous_pointer)/elapsed).limit_length(1800)
	throw_velocity=throw_velocity.lerp(observed,1-exp(-42*elapsed))
	previous_pointer=point
	last_drag_motion=now
	sample_us=tick

func _release(react := true) -> void:
	pressed=false
	var active := bridge.path_join("drag-active.txt")
	if FileAccess.file_exists(active):
		DirAccess.remove_absolute(active)
	gesture_token=0
	release_count+=1
	if motion.held:
		_sample_throw(Vector2(DisplayServer.mouse_get_position()))
		var age := (Time.get_ticks_usec()-sample_us)/1000000.0
		var speed:=throw_velocity*(1-smoothstep(0.07,0.18,age)) if react else Vector2.ZERO
		if speed.length()<90:
			speed=Vector2.ZERO
		motion.release(speed,bool(options.physics),now,0.22)
		_write_position()
	elif react:
		pet_at=-5.0
		click_pose=pressed_zone
		click_at=now
		motion.interrupt(now,bool(options.physics))

func _maybe_grab(global: Vector2) -> void:
	if pressed and not motion.held and global.distance_to(press_origin)>6*float(options.zoom):
		pet_at=-5.0
		click_at=-5.0
		contact=global-motion.position
		motion.grab(now,motion.position.y+body_size.y*DesktopMotion.SEAT_RATIO)
		drag_count+=1

func _menu_action(id: int) -> void:
	_hide_menu()
	if id==20:
		_shutdown()
		return
	var values := _read_json(bridge.path_join("settings.json"),16384)
	if id>=0 and id<MODE_VALUES.size():
		values.mode=MODE_VALUES[id]
	elif id==10:
		values.bubble=not options.bubble
	elif id==11:
		var key := _stocking_key()
		values[key]=not options[key]
	elif id==12:
		values.magic=not options.magic
	if _write_json("settings.json",values):
		poll_clock=0.0

func _is_midnight_loaded() -> bool:
	return _loaded_edition() != "original"

func _loaded_edition() -> String:
	if not str(options.model).is_empty():
		return "original"
	match model_file.get_file():
		"avatar-zxc.vrm","avatar-zxc-stockings.vrm":
			return "zxc"
		"avatar-velvet.vrm","avatar-velvet-stockings.vrm":
			return "velvet"
		"avatar-lunar.vrm","avatar-lunar-stockings.vrm":
			return "lunar"
		"avatar-nocturne.vrm","avatar-nocturne-stockings.vrm":
			return "nocturne"
		"avatar-atelier-refined.vrm","avatar-atelier-refined-stockings.vrm":
			return "atelier_refined"
		"avatar-atelier.vrm","avatar-atelier-stockings.vrm":
			return "atelier"
		"avatar-midnight.vrm","avatar-midnight-stockings.vrm":
			return "midnight"
	return "original"

func _runtime_status() -> Dictionary:
	return {
		"schema":STATUS_SCHEMA,"ready":rig!=null and not stopping,"running":not stopping,
		"model_loaded":rig!=null,"error":model_error,"renderer":renderer,"stage":avatar_state,"paused":paused,
		"bones":rig.skeleton.get_bone_count() if rig!=null else 0,"meshes":rig.meshes.size() if rig!=null else 0,
		"animations":rig.animation_player.get_animation_list().size() if rig!=null and rig.animation_player!=null else 0,
		"mapped_bones":rig.roles.size() if rig!=null else 0,"facial_binds":rig.expression_binds if rig!=null else 0,
		"secondary_bones":rig.secondary.size() if rig!=null else 0,"triangles":rig.triangle_count if rig!=null else 0,
		"outfit_variant":dress_model,"fps":Engine.get_frames_per_second(),"frame_ms":snappedf(sample_ms,0.1),
		"dpi":DisplayServer.screen_get_dpi(get_window().current_screen),"pid":OS.get_process_id(),
		"position":[get_window().position.x,get_window().position.y],"passthrough":passthrough,"menu_open":menu.visible,
		"mouse_interaction":not bool(options.clickthrough),
		"bare_legs_loaded":model_file.get_basename().ends_with("-bare-legs") or _is_midnight_loaded() and model_file.get_file() in ["avatar-midnight.vrm","avatar-atelier.vrm","avatar-atelier-refined.vrm","avatar-nocturne.vrm","avatar-lunar.vrm","avatar-velvet.vrm","avatar-zxc.vrm"],"bubble_visible":bubble.visible,
		"seat_edge":motion.support.position.y if motion.support.has_area() else -1,
		"seat_contact_y":seat_contact_y,"sole_contact_y":sole_contact_y,"edge_count":windows.size(),"impact":motion.impact,
		"cloud":motion.cloud_alpha>0.1,"cloud_seated":motion.cloud_seated,
		"msaa":get_window().msaa_3d,"edition":_loaded_edition(),
		"interactions":interaction_count,"drags":drag_count,"held":motion.held,"releases":release_count,"body_size":[body_size.x,body_size.y]
	}

func _publish() -> void:
	status_clock=0.0
	_write_json("status.json",_runtime_status())

func _write_position() -> void:
	if bool(options.physics) and motion.falling:
		return
	_write_json("position.json",{"x":roundi(motion.position.x),"y":roundi(motion.position.y)})

func _write_json(name: String,value: Dictionary) -> bool:
	var dest := bridge.path_join(name)
	var scratch := dest+"."+str(OS.get_process_id())+".next"
	var file := FileAccess.open(scratch,FileAccess.WRITE)
	if file==null:
		return false
	file.store_string(JSON.stringify(value))
	file.close()
	if DirAccess.rename_absolute(scratch,dest)==OK:
		return true
	# Some Windows file readers briefly lock the destination. Retry the
	# pending settings after the menu releases native focus.
	if name=="settings.json":
		get_tree().create_timer(0.15).timeout.connect(func(): DirAccess.rename_absolute(scratch,dest))
		poll_clock=0.18
	return false

func _shutdown() -> void:
	if stopping:
		return
	stopping=true
	if pressed:_release(false)
	if cached_rig!=null:cached_rig.free_scene()
	_write_position()
	_publish()
	get_tree().quit()
