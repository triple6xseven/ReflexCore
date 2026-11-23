extends SceneTree

const Rig = preload("res://avatar_rig.gd")

func _initialize() -> void:
	call_deferred("_verify")

func _verify() -> void:
	var args := OS.get_cmdline_user_args()
	var rig := Rig.new()
	if args.size()!=1 or not rig.load_file(args[0]):
		push_error("Pass the private default ReflexCompanion VRM to the rig check.")
		quit(2)
		return
	root.add_child(rig.scene)
	var ok := true
	for bone in rig.skirt_roots:
		ok=ok and rig.rotations.has(bone)
	for i in 45:
		rig.animate(1.0/60,i/60.0,"sit",Vector2.ZERO,Vector2.ZERO,true,true,true)
	var hips := rig.world_bone("hips")
	ok=ok and rig.world_bone("leftLowerLeg").z>hips.z+0.12
	ok=ok and rig.world_bone("rightLowerLeg").z>hips.z+0.12
	for frame in 45:
		rig.animate(1.0/60,0.75+frame/60.0,"happy",Vector2.ZERO,Vector2.ZERO,true,true,true)
	for side in ["left","right"]:
		ok=ok and rig.world_bone(side+"Hand").z>hips.z+0.06
	for frame in 45:
		rig.animate(1.0/60,1.5+frame/60.0,"dragged",Vector2.ZERO,Vector2(420,-70),true,true)
	for side in ["left","right"]:
		ok=ok and rig.world_bone(side+"Hand").z>rig.world_bone("chest").z+0.06
	if not ok:
		push_error("Default avatar skirt or hand positioning failed.")
	else:
		print("Default avatar rig: forward seated knees, skirt defaults and visible hands passed.")
	quit(0 if ok else 1)
