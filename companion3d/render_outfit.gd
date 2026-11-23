extends SceneTree
const Rig = preload("res://avatar_rig.gd")

func _initialize() -> void:
	call_deferred("_render")

func _render() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() not in [2,4]:
		quit(2)
		return
	root.size=Vector2i(480,620)
	root.msaa_3d=Viewport.MSAA_4X
	var rig := Rig.new()
	if not rig.load_file(args[0]):
		push_error(rig.error)
		quit(1)
		return
	if args.size()==4:
		rig.set_legwear(true, int(args[2]), args[3])
	root.add_child(rig.scene)
	rig.scene.rotation.y=PI if rig.legacy else 0.0
	var camera := Camera3D.new()
	camera.projection=Camera3D.PROJECTION_ORTHOGONAL
	camera.size=2.0
	camera.current=true
	root.add_child(camera)
	var world := WorldEnvironment.new()
	world.environment=Environment.new()
	world.environment.background_mode=Environment.BG_COLOR
	world.environment.background_color=Color("#252235")
	world.environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_color=Color("#e6e5ff")
	world.environment.ambient_light_energy=0.70
	root.add_child(world)
	var light := DirectionalLight3D.new()
	light.rotation_degrees=Vector3(-31,-23,0)
	light.light_energy=0.85
	root.add_child(light)
	var preview_seat := MeshInstance3D.new()
	preview_seat.mesh=BoxMesh.new()
	preview_seat.mesh.size=Vector3(.80,.20,.55)
	var seat_material := StandardMaterial3D.new()
	seat_material.albedo_color=Color("#4b526a")
	preview_seat.material_override=seat_material
	root.add_child(preview_seat)
	preview_seat.visible=false
	for item in [["front",0.0,false],["three-quarter",.61,false],["profile",PI/2,false],["back",PI,false],["seated-front",0.0,true],["seated",-.63,true],["seated-side",PI/2,true],["seated-stretch",.55,true],["window-crossed",-.63,true],["face",.23,false],["smile",-.2,false],["drag",.55,false],["cloud",-.71,true],["cloud-crossed",-.71,true],["cloud-tucked",-.71,true],["cloud-side",-.71,true],["attentive",.5,true],["thinking",.32,false],["walk",1.25,false],["summon",.5,false],["feet",.45,false],["hover",.65,false]]:
		var pose: String={"cloud":"cloud_sit","attentive":"attentive","thinking":"thinking",
			"smile":"petted","drag":"dragged","walk":"walk","summon":"cloud_summon","hover":"hover"}.get(item[0],"sit" if item[2] else "idle")
		if str(item[0]).begins_with("cloud"):
			pose="cloud_sit"
		if item[0]=="window-crossed" or pose=="cloud_sit":
			rig.animate(1.0/60,0,"idle",Vector2.ZERO,Vector2.ZERO,true,true)
		if pose=="cloud_sit":
			rig.animate(1.0/60,0,pose,Vector2.ZERO,Vector2.ZERO,true,true,true,"",true,true,"relaxed",1.0,false,true)
			var sample := Rig.CLOUD_PREVIEW_SEQUENCE.find({
				"cloud-crossed":Rig.CloudPose.CROSS,"cloud-tucked":Rig.CloudPose.TUCK,
				"cloud-side":Rig.CloudPose.SIDE
			}.get(item[0],Rig.CloudPose.REST))
			rig.cloud_clock=sample*Rig.CLOUD_POSE_SECONDS
		for tick in (440 if item[0]=="window-crossed" else 285 if item[0]=="seated-stretch" else 120 if pose=="cloud_sit" else 95):
			rig.animate(1.0/60.0,float(tick)/60.0,pose,Vector2.ZERO,Vector2(400,-65) if pose=="dragged" else Vector2(115,-32) if pose=="hover" else Vector2.ZERO,true,true,item[2],"",pose=="cloud_sit",item[2],"relaxed",1.0,false,pose=="cloud_sit")
		var closeup: bool=item[0] in ["face","smile","thinking","feet"]
		camera.size=0.54 if closeup else 2.10
		var center := Vector3(0,1.57 if closeup else .88 if item[2] else .95,0)
		if item[0]=="feet":
			center.y=.115
			camera.size=.27
		if item[2]:
			var hips := rig.world_bone("hips")
			preview_seat.position=hips-Vector3.UP*.18-rig.scene.basis*rig.seat_forward*.25
		preview_seat.visible=item[2] and pose!="cloud_sit"
		camera.position=center+Vector3(sin(item[1]),.08,cos(item[1]))*3
		camera.look_at(center)
		await process_frame
		await RenderingServer.frame_post_draw
		if root.get_texture().get_image().save_png(args[1].path_join(item[0]+".png"))!=OK:
			quit(1)
			return
	print(JSON.stringify({"mapped_bones":rig.roles.size(),"facial_binds":rig.expression_binds,"triangles":rig.triangle_count}))
	quit()
