extends SceneTree

const Main = preload("res://main.tscn")
var failed := false

func _initialize() -> void:
	call_deferred("_verify")

func _verify() -> void:
	var avatar = Main.instantiate()
	root.add_child(avatar)
	avatar.set_process(false)
	if avatar.rig==null:
		quit(2)
		return
	avatar.click_at=avatar.now
	for phase in ["approach","reach","grip","pull_up","settle","landing"]:
		_expect(avatar._choose_pose(phase,Vector2.ZERO)==phase,"Click interrupted "+phase)
	_expect(avatar._choose_pose("sit",Vector2.ZERO)=="happy","Seated click lost its reaction.")
	avatar.click_at=-5.0
	avatar.options.mode="stationary"
	avatar._process(1.0/60)
	for tilt in [-0.74,0.74]:
		for frame in 24:
			avatar.motion.angle=tilt
			avatar._process(1.0/60)
		await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		var pixels := image.get_used_rect()
		_expect(pixels.has_area() and root.get_visible_rect().grow(-10).encloses(Rect2(pixels)),
			"An extreme tilt clipped the rendered model: "+str(pixels))
		var outside := 0
		for y in range(pixels.position.y,pixels.end.y,4):
			for x in range(pixels.position.x,pixels.end.x,4):
				if image.get_pixel(x,y).a>0.55 and not Geometry2D.is_point_in_polygon(Vector2(x,y),avatar.native_region):
					outside+=1
		_expect(outside==0,"The Windows input region cut into the silhouette: "+str(outside))

	for previous in ["fall","climb","cloud"]:
		avatar.motion.falling=previous=="fall"
		avatar.motion.climb_progress=0.5 if previous=="climb" else 0.0
		avatar.motion.cloud_seated=previous=="cloud"
		var down := InputEventMouseButton.new()
		down.button_index=MOUSE_BUTTON_LEFT
		down.position=avatar.projected_bones["chest"]
		down.pressed=true
		avatar._input(down)
		var first_token:int=avatar.gesture_token
		var moved:Vector2=avatar.press_origin+Vector2(28,0)
		avatar._maybe_grab(moved)
		_expect(avatar.motion.held and not avatar.motion.falling and avatar.motion.climb_progress==0 and not avatar.motion.cloud_seated,
			"A new drag did not interrupt "+previous)
		avatar._input(down)
		_expect(avatar.pressed and avatar.gesture_token!=first_token,
			"A fresh press did not replace the previous capture.")
		avatar._maybe_grab(avatar.press_origin+Vector2(-28,0))
		_expect(avatar.motion.held,"A fresh press did not permit another drag immediately.")
		down.pressed=false
		avatar._input(down)
		_expect(not avatar.motion.held and not avatar.pressed,"Mouse-up did not clear the current drag.")
	var right := InputEventMouseButton.new()
	right.button_index=MOUSE_BUTTON_RIGHT
	right.position=avatar.projected_bones["chest"]
	right.pressed=true
	avatar._input(right)
	_expect(avatar.menu.visible,"Right click must open the overlay menu.")
	var far_corner := Vector2.ZERO
	avatar._track_input(far_corner,1.0/60)
	_expect(avatar.passthrough,"An open menu must pass through the background immediately.")
	avatar.now+=0.25
	avatar._track_input(far_corner,1.0/60)
	_expect(not avatar.menu.visible and avatar.passthrough,"Leaving the menu did not return control.")
	avatar._input(right)
	_expect(avatar.menu.visible,"The menu did not reopen after dismissing it.")
	avatar.menu_buttons[20].pressed.emit()
	_expect(avatar.stopping and not avatar.menu.visible,"The menu close action did not stop the overlay.")
	if not failed:
		print("Windows overlay: full alpha bounds at both extreme tilts; immediate re-grab, dismissible menu, background passthrough and close action passed.")
	avatar.queue_free()
	quit(1 if failed else 0)

func _expect(ok: bool, message: String) -> void:
	if not ok:
		failed=true
		push_error(message)
