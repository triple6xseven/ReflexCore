extends SceneTree

const Main = preload("res://main.tscn")
const Rig = preload("res://avatar_rig.gd")
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
	_check_cloud_turn(avatar)
	var rig = avatar.rig
	for pose in ["petted","dragged","thrown","hard_collision","landing","thinking","working","reach","sit","cloud_sit"]:
		var classic := Vector3.ZERO
		var seat: bool = pose in ["sit","cloud_sit"]
		var joint := "leftFoot" if seat else "rightHand"
		for visit in 3:
			for frame in 90:
				rig.animate(1.0/60,frame/60.0,"idle",Vector2.ZERO,Vector2.ZERO,true,true)
			for frame in 90:
				rig.animate(1.0/60,frame/60.0,pose,Vector2.ZERO,Vector2.ZERO,true,true,seat,"",pose=="cloud_sit",seat,"relaxed")
			var point: Vector3 = rig.world_bone(joint)
			if visit==0:
				classic=point
			var variant: bool = rig.alternate_seat if seat else rig.alternate
			_expect(variant==(visit==1),"Wrong rotation for "+pose)
			if visit==1:
				_expect(point.distance_to(classic)>.001,"No joint variation in "+pose)
	_check_seated_variations(rig)
	avatar.click_at=avatar.now
	for phase in ["approach","reach","grip","pull_up","settle","landing"]:
		_expect(avatar._choose_pose(phase,INF)==phase,"Click interrupted "+phase)
	_expect(avatar._choose_pose("sit",INF)=="happy","Seated click lost its reaction.")
	avatar.click_at=-5.0
	avatar.options.mode="stationary"
	avatar._process(1.0/60)
	_expect(avatar._click_pose_at(avatar.head)=="face_smile","Face touch missed.")
	_expect(avatar._click_pose_at(avatar.projected_bones.leftFoot)=="tickled","Foot touch missed.")
	avatar.motion.impact="floor"
	avatar.motion.impact_speed=420
	avatar.motion.impact_at=avatar.now
	avatar._update_contact_effect()
	_expect(avatar.contact_ring.visible and avatar.contact_ring.points.size()==25,"Landing ring missing.")
	avatar.motion.impact_at=avatar.now-1
	avatar._update_contact_effect()
	_expect(not avatar.contact_ring.visible,"Landing ring outlived its impact.")
	var expected_position := root.position
	root.position+=Vector2i(36,0)
	avatar._process(1.0/60)
	_expect(root.position==expected_position,"A stationary overlay did not recover its desktop position.")
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
	avatar.preview_until=avatar.now+5.0
	avatar._input(right)
	_expect(avatar.preview_until<=avatar.now,"Right click must cancel Dev preview.")
	_expect(avatar.menu.visible,"Right click must open the overlay menu.")
	var far_corner := Vector2.ZERO
	avatar._track_input(far_corner,far_corner,INF)
	_expect(avatar.passthrough,"An open menu must pass through the background immediately.")
	avatar.now+=0.25
	avatar._track_input(far_corner,far_corner,INF)
	_expect(not avatar.menu.visible and avatar.passthrough,"Leaving the menu did not return control.")
	avatar._input(right)
	_expect(avatar.menu.visible,"The menu did not reopen after dismissing it.")
	avatar.menu_buttons[20].pressed.emit()
	_expect(avatar.stopping and not avatar.menu.visible,"The menu close action did not stop the overlay.")
	if not failed:
		print("Windows overlay: stable cloud turns, attentive hover hysteresis, full alpha bounds at both extreme tilts; immediate re-grab, dismissible menu, background passthrough and close action passed.")
	avatar.queue_free()
	quit(1 if failed else 0)

func _check_seated_variations(rig: RefCounted) -> void:
	const FRAME := 1.0/60
	_expect(Rig.CLOUD_SEQUENCE.count(Rig.CloudPose.TUCK)*6<=Rig.CLOUD_SEQUENCE.size(),
		"Knee tucks must occupy at most half the previous share of cloud poses")
	for cloudy in [false,true]:
		rig.animate(FRAME,0,"idle",Vector2.ZERO,Vector2.ZERO,true,true)
		var sides: Array[float] = []
		var crossing := false
		var tucked := false
		var hugs := 0
		# Standalone preview shows both leg orders before the tucked variation.
		for tick in 1500:
			rig.animate(FRAME,tick*FRAME,"cloud_sit" if cloudy else "sit",Vector2.ZERO,Vector2.ZERO,true,true,true,"",cloudy,true,"relaxed",1.0,false,true)
			if rig.crossed>.99 and not crossing:
				sides.append(rig.cross_direction)
				var left: Vector3 = rig.world_bone("leftLowerLeg")
				var right: Vector3 = rig.world_bone("rightLowerLeg")
				_expect(signf(left.y-right.y)==rig.cross_direction,"Raised knee must match the crossed side")
			crossing=rig.crossed>.99
			if rig.hug_progress>.9 and not tucked:
				hugs+=1
			tucked=rig.hug_progress>.9
		_expect(sides.size()==2 and sides[0]==-sides[1],"Seated leg crossings must alternate legs")
		_expect(hugs==(1 if cloudy else 0),"Only the cloud preview should briefly tuck the knees")
		rig.animate(FRAME,30,"sit",Vector2.ZERO,Vector2.ZERO,true,true,true,"",cloudy,true,"still")
		_expect(rig.crossed==0.0,"Still must suppress crossing")

func _check_cloud_turn(avatar: Node) -> void:
	avatar.pivot.rotation.y=-.77
	avatar.cloud_turn_target=-.77
	for direction in [1.0,-1.0]:
		for tick in 100:
			var before: float=avatar.pivot.rotation.y
			avatar._update_facing(1.0/60,true,direction*240,0)
			var step: float=(avatar.pivot.rotation.y-before)*direction
			_expect(step>=-.00001 and step<.063,"Discontinuous cloud turn")
		_expect(absf(avatar.pivot.rotation.y-direction*.77)<.006,"Failed to face cursor")
		# A transient sample or animated body overlap must not reverse the seat.
		for tick in 60:
			var offset: float=-direction*(240.0 if tick%3==0 else 12.0)
			avatar._update_facing(1.0/60,true,offset,0)
		_expect(absf(avatar.pivot.rotation.y-direction*.77)<.006,"Cloud reacted to a brief cursor crossing")
		for tick in 24:
			avatar._update_facing(1.0/60,true,-direction*240,0,false)
		_expect(avatar.cloud_look_side==direction,"Cloud changed sides in transit")
	if avatar.rig.refined:
		_expect(avatar._choose_pose("cloud_sit",20)=="attentive","Failed to notice the cursor")
		for distance in [33.0,41.0,50.0,32.0]:
			_expect(avatar._choose_pose("cloud_sit",distance)=="attentive","Attentive pose flickered")
		_expect(avatar._choose_pose("cloud_sit",55)=="cloud_sit","Attentive pose stayed latched")
	avatar._update_facing(1.0/60,false,240,0)
	_expect(not avatar.cloud_turning,"Cloud turn leaked into another state")

func _expect(ok: bool, message: String) -> void:
	if not ok:
		failed=true
		push_error(message)
