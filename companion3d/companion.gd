extends Node

const Rig = preload("res://avatar_rig.gd")
const DesktopMotion = preload("res://desktop_motion.gd")
const BASE_SIZE := Vector2i(344, 500)
const STATUS_SCHEMA := "reflexcore.companion.runtime.v1"
const DEFAULTS := {
	"model": "", "mode": "taskbar", "x": -1, "y": -1, "zoom": 1.0, "physics": true,
	"gravity": 900.0, "walk_speed": 58.0, "hair": true, "stockings": true,
	"animate": true, "bubble": true, "top": true, "clickthrough": false, "fps": 30,
	"bubble_style": "glass", "poll_ms": 400
}
const MODE_NAMES := ["Stationary", "Taskbar Companion", "Window Companion", "Free Roam", "Follow Cursor"]
const MODE_VALUES := ["stationary", "taskbar", "windows", "roam", "follow"]
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
var menu: PopupMenu
var rig: RefCounted
var model_file := ""
var model_error := ""
var model_attempt_at := 0.0
var model_mtime := 0
var motion := DesktopMotion.new()
var windows: Array[Rect2i] = []
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
var click_at := -5.0
var pet_at := -5.0
var pressed := false
var contact := Vector2.ZERO
var previous_pointer := Vector2.ZERO
var gesture_direction := 0.0
var gesture_extent := 0.0
var gesture_turns := 0
var gesture_at := 0.0
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
var last_window_position := Vector2i.ZERO
var interaction_count := 0
var drag_count := 0

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty() or not args[0].is_absolute_path() or not DirAccess.dir_exists_absolute(args[0]):
		push_error("Pass the private ReflexCore bridge directory after --.")
		get_tree().quit(2)
		return
	bridge = args[0]
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
	_apply_options()
	_restore_position()
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
	menu = PopupMenu.new()
	add_child(menu)
	for i in MODE_NAMES.size():
		menu.add_radio_check_item(MODE_NAMES[i],i)
	menu.add_separator()
	menu.add_check_item("Show status bubble",10)
	menu.add_check_item("Stockings",11)
	menu.add_item("Close ReflexCompanion",20)
	menu.id_pressed.connect(_menu_action)

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
	next.poll_ms = clampi(int(next.poll_ms),200,2500)
	if next.model is String and (not next.model.is_absolute_path() or next.model.length()>3000):
		next.model = ""
	return next

func _pick_model() -> String:
	var desired: String = options.model
	dress_model=false
	if desired.is_empty():
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
	if now < model_attempt_at:
		return
	model_attempt_at=now+3.0
	model_file=path
	model_mtime=touched
	var candidate := Rig.new()
	if not candidate.load_file(path):
		model_error=candidate.error
		return
	# Import first. An invalid replacement never removes the working character.
	if rig!=null and is_instance_valid(rig.scene):
		pivot.remove_child(rig.scene)
		rig.free_scene()
	rig=candidate
	pivot.add_child(rig.scene)
	var size_factor:=1.65/float(rig.height)
	rig.scene.scale=Vector3.ONE*size_factor
	rig.scene.position.y=-float(rig.bottom)*size_factor
	rig.scene.rotation.y=PI if rig.legacy else 0
	model_error=""
	_camera_layout()

func _apply_options() -> void:
	var window := get_window()
	var desired := Vector2i(Vector2(BASE_SIZE)*float(options.zoom))
	var old_size := window.size
	if old_size!=desired:
		window.size=desired
		if not initial:
			motion.position+=Vector2(float(old_size.x-desired.x)/2,float(old_size.y-desired.y))
	window.always_on_top=bool(options.top)
	bubble_style.bg_color=Color("#101b27e9") if options.bubble_style=="minimal" else Color("#182238ed")
	bubble_style.set_corner_radius_all(5 if options.bubble_style=="minimal" else 13)
	_camera_layout()

func _camera_layout() -> void:
	var h := float(get_window().size.y)
	if h < 170:
		return
	var horizontal_pad := 113.0 * float(options.zoom)
	camera.size=1.65*h/(h-horizontal_pad)
	camera.position.y=(0.5-39.0/h)*camera.size

func _screen_rect() -> Rect2i:
	var screen := get_window().current_screen
	if screen<0 or screen>=DisplayServer.get_screen_count():
		screen=DisplayServer.get_primary_screen()
	var rect := DisplayServer.screen_get_usable_rect(screen)
	return rect if rect.has_area() else Rect2i(Vector2i.ZERO,Vector2i(1920,1080))

func _restore_position() -> void:
	var area := _screen_rect()
	var size := get_window().size
	var fallback := Vector2i(area.end.x-size.x-18, area.end.y-size.y+20)
	var saved := _read_json(bridge.path_join("position.json"),1024)
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
	get_window().position=Vector2i(motion.position)
	last_window_position=get_window().position
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
			windows.clear()
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
	var bounds: Variant = live.get("bounds",[])
	windows.clear()
	if bounds is Array:
		for rect in bounds:
			if not rect is Array or rect.size()!=4:
				continue
			var b := Rect2i(int(rect[0]),int(rect[1]),clampi(int(rect[2]),0,20000),clampi(int(rect[3]),0,20000))
			if b.has_area():
				windows.append(b)
			if windows.size()>=24:
				break

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
	poll_clock-=delta
	status_clock+=delta
	if poll_clock<=0:
		_poll()
		poll_clock=float(options.poll_ms)/1000.0
	if stopping:
		return
	var window := get_window()
	if paused:
		window.visible=false
		shown=false
		Engine.max_fps=10
		if status_clock>=1.8:
			_publish()
		return
	if not shown:
		window.visible=true
		shown=true
	var dt := clampf(delta,0.001,0.05)
	sample_ms=lerpf(sample_ms,1000.0*delta,0.09)
	var pointer := DisplayServer.mouse_get_position()
	var local := Vector2(pointer-window.position)
	var area := _screen_rect()
	if motion.held:
		var wanted := Vector2(pointer)-contact
		# Follow the cursor between displays while leaving all applications untouched.
		motion.drag_to(wanted,throw_velocity,dt)
	var physical: String = motion.update(dt,now,area,window.size,pointer,options,windows)
	var actual:=Vector2i(motion.position)
	if actual!=last_window_position:
		window.position=actual
		last_window_position=actual
	if had_motion and not motion.falling and not motion.held:
		_write_position()
	had_motion=motion.falling or motion.held
	avatar_state=_choose_pose(physical,local)
	if rig!=null:
		for role in rig.roles:
			projected_bones[role]=camera.unproject_position(rig.world_bone(role))
		head=projected_bones["head"]
		var gaze := (local-head)/145.0
		if not _near_model(local,52):
			gaze=Vector2(sin(now*0.48)*0.32,sin(now*0.28)*0.13)
		if stage=="warning":
			gaze.y=-0.55
		rig.animate(dt,now,avatar_state,gaze,motion.velocity,bool(options.hair),bool(options.animate))
		var yaw := (gaze.x*0.08 + clampf(motion.velocity.x/1150.0,-0.23,0.23))
		pivot.rotation.y=lerpf(pivot.rotation.y,yaw,minf(5*dt,1))
	_update_bubble()
	_track_input(local,dt)
	var interactive := pressed or motion.falling or avatar_state in ["walk","run","landing","petted"] or _near_model(local,25)
	Engine.max_fps=clampi(int(options.fps),15,60) if interactive else mini(24,int(options.fps))
	if status_clock>=1.8:
		_publish()
	if smoke_time>0 and now>=smoke_time:
		if not smoke_path.is_empty():
			var image := get_viewport().get_texture().get_image()
			if image!=null:
				image.save_png(smoke_path)
		print(JSON.stringify(_runtime_status()))
		_shutdown()

func _choose_pose(physical: String, local: Vector2) -> String:
	if physical in ["dragged","falling","landing","recovering","run","walk"]:
		return physical
	if now-pet_at<1.6:
		return "petted"
	if now-click_at<1.65 or stage=="success" and now-stage_at<4.2:
		return "happy"
	if stage=="warning" and now-stage_at<9.0:
		return "warning"
	if stage in ["thinking","working"]:
		return stage
	if stage=="observing" or _near_model(local,25):
		return "curious"
	return physical

func _update_bubble() -> void:
	var window_size := Vector2(get_window().size)
	var visible := bool(options.bubble) or rig==null
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
	var text := _bubble_message()
	if text!=bubble_label.text:
		bubble_label.text=text
		bubble.modulate.a=0.66
	bubble.modulate.a=move_toward(bubble.modulate.a,1,0.08)

func _bubble_message() -> String:
	if rig==null:
		return "Choose a rigged VRM or GLB in Studio."
	if now-pet_at<1.6:
		return "✦"
	var slot := int(now/5)%3
	if slot==2 and show_metrics and not metrics.is_empty():
		return metrics[int(now/15.0)%metrics.size()]
	if slot==1 and pending>0:
		return ("%d task waiting" if pending==1 else "%d tasks waiting")%pending
	if not message.is_empty() and stage!="idle":
		return message
	return {"thinking":"Thinking…","working":"Working…","observing":"Observing",
		"success":"Task complete","warning":"Task needs attention"}.get(stage,"Idle")

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

func _track_input(local: Vector2, dt: float) -> void:
	# Leave the rendered pixels intact while letting clicks outside projected hit
	# zones reach the desktop. No polling of other applications' input.
	var can_click := _near_model(local,4) or (rig==null and bubble.get_rect().has_point(local))
	_set_cursor_passthrough(bool(options.clickthrough) or not (pressed or can_click or menu.visible))
	if pressed:
		var global := Vector2(DisplayServer.mouse_get_position())
		var observed := (global-previous_pointer)/dt
		throw_velocity=throw_velocity.lerp(observed.limit_length(1300),minf(24*dt,1))
		previous_pointer=global
		_maybe_grab(global)
		if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and Time.get_ticks_msec()-pressed_at>100:
			_release()
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
			gesture_turns=0

func _set_cursor_passthrough(value: bool) -> void:
	if value==passthrough:
		return
	passthrough=value
	get_window().mouse_passthrough=value

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and pressed:
		var movement := event as InputEventMouseMotion
		_maybe_grab(Vector2(get_window().position)+movement.position)
	if not event is InputEventMouseButton or bool(options.clickthrough):
		return
	var mouse := event as InputEventMouseButton
	var position := Vector2(get_window().position)+mouse.position
	if mouse.button_index==MOUSE_BUTTON_RIGHT and mouse.pressed and _near_model(mouse.position,6):
		for i in MODE_VALUES.size():
			menu.set_item_checked(i,MODE_VALUES[i]==options.mode)
		menu.set_item_checked(menu.get_item_index(10),bool(options.bubble))
		menu.set_item_checked(menu.get_item_index(11),bool(options.stockings))
		menu.position=Vector2i(position)
		menu.popup()
		return
	if mouse.button_index!=MOUSE_BUTTON_LEFT:
		return
	if mouse.pressed and _near_model(mouse.position,6):
		if mouse.double_click:
			click_at=now
		pressed=true
		pressed_at=Time.get_ticks_msec()
		interaction_count+=1
		contact=position-motion.position
		previous_pointer=position
		throw_velocity=Vector2.ZERO
	elif not mouse.pressed and pressed:
		_maybe_grab(position)
		_release(position)

func _release(pointer := Vector2.INF) -> void:
	if not pointer.is_finite():
		pointer=Vector2(DisplayServer.mouse_get_position())
	pressed=false
	if motion.held:
		var anchor := pointer-contact
		motion.drag_to(anchor,throw_velocity,0.024)
		var speed:=throw_velocity
		if speed.length()<90:
			speed=Vector2.ZERO
		motion.release(speed,bool(options.physics),now)
		_write_position()
	else:
		click_at=now

var pressed_at := 0

func _maybe_grab(global: Vector2) -> void:
	if pressed and not motion.held and (global-motion.position-contact).length()>7*float(options.zoom):
		motion.grab()
		drag_count+=1

func _menu_action(id: int) -> void:
	if id==20:
		_shutdown()
		return
	var values := _read_json(bridge.path_join("settings.json"),16384)
	if id>=0 and id<MODE_VALUES.size():
		values.mode=MODE_VALUES[id]
	elif id==10:
		values.bubble=not options.bubble
	elif id==11:
		values.stockings=not options.stockings
	_write_json("settings.json",values)

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
		"position":[get_window().position.x,get_window().position.y],"passthrough":passthrough,
		"interactions":interaction_count,"drags":drag_count
	}

func _publish() -> void:
	status_clock=0.0
	_write_json("status.json",_runtime_status())

func _write_position() -> void:
	if bool(options.physics) and motion.falling:
		return
	_write_json("position.json",{"x":get_window().position.x,"y":get_window().position.y})

func _write_json(name: String,value: Dictionary) -> void:
	var dest := bridge.path_join(name)
	var scratch := dest+"."+str(OS.get_process_id())+".next"
	var file := FileAccess.open(scratch,FileAccess.WRITE)
	if file==null:
		return
	file.store_string(JSON.stringify(value))
	file.close()
	DirAccess.rename_absolute(scratch,dest)

func _shutdown() -> void:
	if stopping:
		return
	stopping=true
	_write_position()
	_publish()
	get_tree().quit()
