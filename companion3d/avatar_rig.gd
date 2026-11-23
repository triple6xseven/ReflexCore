extends RefCounted

const MAX_BYTES := 96 * 1024 * 1024
const REQUIRED := ["hips", "head", "leftUpperArm", "rightUpperArm", "leftUpperLeg", "rightUpperLeg"]
const ROLE_ALIAS := {
	"hips": ["hips", "pelvis", "jbipchips"], "head": ["head", "jbipchead"],
	"spine": ["spine", "jbipcspine"], "chest": ["chest", "spine1", "jbipcchest"],
	"neck": ["neck", "jbipcneck"], "leftUpperArm": ["leftarm", "upperarml", "jbiplupperarm"],
	"rightUpperArm": ["rightarm", "upperarmr", "jbiprupperarm"],
	"leftLowerArm": ["leftforearm", "forearml", "jbipllowerarm"], "rightLowerArm": ["rightforearm", "forearmr", "jbiprlowerarm"],
	"leftHand": ["lefthand", "handl", "jbipllhand", "jbiplhand"], "rightHand": ["righthand", "handr", "jbiprhand"],
	"leftUpperLeg": ["leftupleg", "thighl", "jbiplupperleg"], "rightUpperLeg": ["rightupleg", "thighr", "jbiprupperleg"],
	"leftLowerLeg": ["leftleg", "shinl", "jbipllowerleg"], "rightLowerLeg": ["rightleg", "shinr", "jbiprlowerleg"],
	"leftFoot": ["leftfoot", "footl", "jbiplfoot"], "rightFoot": ["rightfoot", "footr", "jbiprfoot"],
	"leftEye": ["lefteye", "eyel"], "rightEye": ["righteye", "eyer"]
}

var scene: Node3D
var skeleton: Skeleton3D
var meshes: Array[MeshInstance3D] = []
var roles: Dictionary = {}
var expressions: Dictionary = {}
var secondary: Array[int] = []
var skirt_roots: Array[int] = []
var animation_player: AnimationPlayer
var natural: Dictionary = {}
var rotations: Dictionary = {}
var starting_positions: Dictionary = {}
var bone_name_ids: Dictionary = {}
var height := 1.65
var bottom := 0.0
var legacy := false
var error := ""
var license_data := {}
var expression_binds := 0
var triangle_count := 0
var state := "idle"
var stance := 0.0
var posture := 0.0
var step_phase := 0.0
var gait := 0.0
var secondary_motion := Vector2.ZERO
var secondary_velocity := Vector2.ZERO
var look := Vector2.ZERO
var face := Vector2.ZERO
var last_expression: Dictionary = {}
var gesture_weight := 0.0
var gesture_state := ""
var midnight: BoneAttachment3D
var midnight_materials := {}

func load_file(path: String) -> bool:
	var input := FileAccess.open(path, FileAccess.READ)
	if input == null:
		error = "model_missing"
		return false
	var size := input.get_length()
	if size < 24 or size > MAX_BYTES:
		error = "model_size"
		return false
	var bytes := input.get_buffer(size)
	if bytes.size() != size or bytes.decode_u32(0) != 0x46546c67 or bytes.decode_u32(4) != 2 or bytes.decode_u32(8) != size:
		error = "invalid_glb"
		return false
	var json_size := bytes.decode_u32(12)
	if json_size < 2 or json_size > 8 * 1024 * 1024 or json_size + 20 > size or bytes.decode_u32(16) != 0x4e4f534a:
		error = "invalid_glb"
		return false
	var source: Variant = JSON.parse_string(bytes.slice(20, 20 + json_size).get_string_from_utf8())
	if not source is Dictionary or not _bounded(source):
		error = "invalid_model_metadata"
		return false
	var document := GLTFDocument.new()
	var gltf := GLTFState.new()
	# Embedded textures stay in memory and no external files can be resolved.
	gltf.handle_binary_image = GLTFState.HANDLE_BINARY_EMBED_AS_UNCOMPRESSED
	if document.append_from_buffer(bytes, "", gltf) != OK:
		error = "gltf_import_failed"
		return false
	var rendered: Node = document.generate_scene(gltf, 30)
	if not rendered is Node3D:
		if rendered != null:
			rendered.free()
		error = "scene_missing"
		return false
	scene = rendered as Node3D
	_collect(scene)
	if skeleton == null or meshes.is_empty() or skeleton.get_bone_count() > 512:
		free_scene()
		error = "rig_missing"
		return false
	for i in skeleton.get_bone_count():
		bone_name_ids[_normalize(String(skeleton.get_bone_name(i)))] = i
	var extensions: Dictionary = source.get("extensions", {})
	var vrm0: Dictionary = extensions.get("VRM", {})
	var vrm1: Dictionary = extensions.get("VRMC_vrm", {})
	legacy = not vrm0.is_empty()
	var vrm_humanoid: Dictionary = vrm0.get("humanoid", {}) if legacy else vrm1.get("humanoid", {})
	var human: Variant = vrm_humanoid.get("humanBones", [] if legacy else {})
	if legacy and human is Array:
		for item in human:
			if item is Dictionary:
				_map_role(source, str(item.get("bone", "")), int(item.get("node", -1)))
	elif human is Dictionary:
		for role in human:
			if human[role] is Dictionary:
				_map_role(source, str(role), int(human[role].get("node", -1)))
	for role in ROLE_ALIAS:
		if roles.has(role):
			continue
		var aliases: Array = ROLE_ALIAS[role] + [_normalize(role)]
		for key in bone_name_ids:
			var short_key: String = key.trim_prefix("mixamorig").trim_prefix("bip01")
			if short_key in aliases:
				roles[role] = bone_name_ids[key]
				break
	for role in REQUIRED:
		if not roles.has(role):
			free_scene()
			error = "humanoid_map_incomplete"
			return false
	license_data = vrm0.get("meta", {}) if legacy else vrm1.get("meta", {})
	_setup_expressions(source, vrm0, vrm1, gltf)
	_setup_secondary(source, vrm0, extensions)
	var head := bone_position("head")
	var left := bone_position("leftFoot", bone_position("leftUpperLeg") - Vector3.UP * 0.72)
	var right := bone_position("rightFoot", bone_position("rightUpperLeg") - Vector3.UP * 0.72)
	bottom = minf(left.y, right.y) - 0.075
	height = head.y - bottom + 0.23
	if height < 0.3 or height > 40.0:
		free_scene()
		error = "unsupported_rig_scale"
		return false
	for key in roles.values():
		var bone: int = key
		rotations[bone] = skeleton.get_bone_pose_rotation(bone)
		starting_positions[bone] = skeleton.get_bone_pose_position(bone)
	for bone in secondary+skirt_roots:
		rotations[bone] = skeleton.get_bone_pose_rotation(bone)
	for side in ["left","right"]:
		_lower_arm(side)
	return true

func free_scene() -> void:
	if is_instance_valid(scene):
		scene.free()
	scene = null

func _bounded(source: Dictionary) -> bool:
	for field in ["extensions", "asset"]:
		if source.has(field) and not source[field] is Dictionary:
			return false
	for field in ["nodes", "meshes", "buffers", "images", "skins", "accessors", "materials"]:
		var value: Variant = source.get(field, [])
		if not value is Array or value.size() > 4096:
			return false
		for el in value:
			if not el is Dictionary:
				return false
	for field in ["buffers", "images"]:
		for item in source.get(field, []):
			if item.has("uri"):
				return false
	# Restrict compressed accessors before Godot allocates drawing buffers.
	var vertices := 0
	for mesh in source.get("meshes", []):
		var primitives: Variant = mesh.get("primitives", [])
		if not primitives is Array or primitives.size() > 96:
			return false
		for primitive in primitives:
			if not primitive is Dictionary or not primitive.get("attributes", {}) is Dictionary:
				return false
			var index := int(primitive.get("attributes", {}).get("POSITION", -1))
			var accessors: Array = source.get("accessors", [])
			if index < 0 or index >= accessors.size():
				return false
			vertices += int(accessors[index].get("count", 0))
			var index_id := int(primitive.get("indices", -1))
			if index_id >= 0 and index_id < accessors.size():
				triangle_count += int(accessors[index_id].get("count", 0)) / 3
			if vertices > 800000:
				return false
	return vertices > 0 and source.get("skins", []).size() <= 16

func _collect(node: Node) -> void:
	if node is Skeleton3D:
		if skeleton == null or node.get_bone_count() > skeleton.get_bone_count():
			skeleton = node
	elif node is MeshInstance3D and node.mesh != null:
		meshes.append(node)
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	elif node is AnimationPlayer:
		if animation_player == null:
			animation_player = node
		node.stop()
	for child in node.get_children():
		_collect(child)

func _normalize(str_name: String) -> String:
	var out := ""
	for character in str_name.to_lower():
		if character >= "a" and character <= "z" or character >= "0" and character <= "9":
			out += character
	return out

func _bone_for_node(source: Dictionary, node: int) -> int:
	var nodes: Array = source.get("nodes", [])
	if node < 0 or node >= nodes.size():
		return -1
	return int(bone_name_ids.get(_normalize(str(nodes[node].get("name", ""))), -1))

func _map_role(source: Dictionary, role: String, node: int) -> void:
	var index := _bone_for_node(source, node)
	if ROLE_ALIAS.has(role) and index >= 0:
		roles[role] = index

func _setup_secondary(source: Dictionary, vrm0: Dictionary, extensions: Dictionary) -> void:
	var manifest: Variant = vrm0.get("secondaryAnimation", {})
	var spring: Variant = extensions.get("VRMC_springBone", {})
	var candidates: Array[int] = []
	if manifest is Dictionary:
		for group in manifest.get("boneGroups", []):
			if group is Dictionary:
				for index in group.get("bones", []):
					candidates.append(_bone_for_node(source, int(index)))
	if spring is Dictionary:
		for group in spring.get("springs", []):
			if group is Dictionary:
				var joints: Variant = group.get("joints", [])
				if joints is Array and not joints.is_empty() and joints[0] is Dictionary:
					candidates.append(_bone_for_node(source, int(joints[0].get("node", -1))))
	if candidates.is_empty():
		for i in skeleton.get_bone_count():
			var display := str(skeleton.get_bone_name(i)).to_lower()
			if "hair" in display or "skirt" in display:
				candidates.append(i)
	for i in skeleton.get_bone_count():
		var display := String(skeleton.get_bone_name(i)).to_lower()
		if display.ends_with("0") and ("skirtfront" in display or "skirtside" in display):
			skirt_roots.append(i)
	for bone in candidates:
		if secondary.size() >= 22:
			break
		if bone >= 0 and not roles.values().has(bone) and bone not in secondary:
			secondary.append(bone)

func _expression_key(name: String) -> String:
	var key := _normalize(name)
	if key in ["blink", "eyeblink", "blinkboth", "fclallclose", "fclallblink", "fcleyeclose"]:
		return "blink"
	if key in ["joy", "happy", "smile", "fun", "fclalljoy", "fclallfun"]:
		return "happy"
	if key in ["sorrow", "sad", "angry", "fclallsorrow", "fclallangry"]:
		return "warning"
	return ""

func _add_expression(key: String, mesh: MeshInstance3D, index: int, weight: float) -> void:
	if key.is_empty() or index < 0 or index >= mesh.get_blend_shape_count():
		return
	if not expressions.has(key):
		expressions[key] = []
	var list: Array = expressions[key]
	for prior in list:
		if prior[0] == mesh and prior[1] == index:
			return
	list.append([mesh, index, clampf(weight, 0, 1)])
	expression_binds += 1

func _setup_expressions(source: Dictionary, vrm0: Dictionary, vrm1: Dictionary, gltf: GLTFState) -> void:
	var groups: Variant = vrm0.get("blendShapeMaster", {})
	if groups is Dictionary:
		var gltf_meshes := gltf.get_meshes()
		for value in groups.get("blendShapeGroups", []):
			if not value is Dictionary:
				continue
			var key := _expression_key(str(value.get("presetName", "")))
			if key.is_empty() or expressions.has(key):
				continue
			for binding in value.get("binds", []):
				if not binding is Dictionary:
					continue
				var mesh_id := int(binding.get("mesh", -1))
				if mesh_id < 0 or mesh_id >= gltf_meshes.size():
					continue
				var importer := gltf_meshes[mesh_id].mesh
				for mesh in meshes:
					if mesh.mesh.resource_name == importer.resource_name or mesh.mesh.get_blend_shape_count() == importer.get_blend_shape_count():
						_add_expression(key, mesh, int(binding.get("index", -1)), float(binding.get("weight", 100)) / 100)
	var v1: Variant = vrm1.get("expressions", {})
	if v1 is Dictionary:
		var presets: Variant = v1.get("preset", {})
		if presets is Dictionary:
			for name in presets:
				var key := _expression_key(name)
				if key.is_empty() or expressions.has(key) or not presets[name] is Dictionary:
					continue
				for binding in presets[name].get("morphTargetBinds", []):
					if not binding is Dictionary:
						continue
					var node_index := int(binding.get("node", -1))
					var nodes: Array = source.get("nodes", [])
					if node_index < 0 or node_index >= nodes.size():
						continue
					var name_key := _normalize(str(nodes[node_index].get("name", "")))
					for mesh in meshes:
						if _normalize(str(mesh.name)) == name_key:
							_add_expression(key, mesh, int(binding.get("index", -1)), float(binding.get("weight", 1)))
	for mesh in meshes:
		for index in mini(mesh.get_blend_shape_count(), 160):
			var key := _expression_key(str(mesh.mesh.get_blend_shape_name(index)))
			if not expressions.has(key):
				_add_expression(key, mesh, index, 1)

func _lower_arm(side: String) -> void:
	var upper := int(roles.get(side + "UpperArm", -1))
	var lower := int(roles.get(side + "LowerArm", -1))
	if upper < 0 or lower < 0:
		return
	var arm := skeleton.get_bone_global_rest(upper)
	var elbow := skeleton.get_bone_global_rest(lower)
	var direction := (elbow.origin - arm.origin).normalized()
	var goal := Vector3(direction.x * 0.23, -0.97, 0.025).normalized()
	var parent := skeleton.get_bone_parent(upper)
	var basis := skeleton.get_bone_global_rest(parent).basis.orthonormalized().inverse() if parent >= 0 else Basis.IDENTITY
	var turn := Quaternion(basis * direction, basis * goal)
	natural[upper] = turn * rotations[upper]

func _pose(role: String, euler: Vector3, weight: float) -> void:
	var bone := int(roles.get(role, -1))
	if bone < 0:
		return
	var rest: Quaternion = natural.get(bone, rotations.get(bone, Quaternion.IDENTITY))
	var target := (rest * Quaternion.from_euler(euler)).normalized()
	skeleton.set_bone_pose_rotation(bone, skeleton.get_bone_pose_rotation(bone).slerp(target, weight))

func bone_position(role: String, fallback := Vector3.ZERO) -> Vector3:
	var bone := int(roles.get(role, -1))
	if bone < 0:
		return fallback
	return skeleton.get_bone_global_pose(bone).origin

func world_bone(role: String) -> Vector3:
	return skeleton.to_global(bone_position(role))

func _morph(key: String, value: float) -> void:
	if absf(float(last_expression.get(key, -1)) - value) < 0.02:
		return
	last_expression[key] = value
	for binding in expressions.get(key, []):
		var mesh: MeshInstance3D = binding[0]
		mesh.set_blend_shape_value(binding[1], value * binding[2])

func animate(dt: float, now: float, next: String, cursor: Vector2, motion: Vector2, hair: bool, enabled: bool, seated: bool=false, impact: String="") -> void:
	state = next
	var blend := 1.0 - exp(-10.0 * dt)
	var moving := state in ["walk", "run"]
	gait = lerpf(gait, 1.0 if moving and enabled else 0.0, blend)
	stance = lerpf(stance, 1.0 if seated else 0.0, blend)
	posture = lerpf(posture, float({"thinking": 0.16, "working": 0.08, "sleepy": 0.24, "falling": -0.13,
		"dragged": -0.14, "thrown": -0.24, "landing": 0.28, "recovering": 0.12, "petted": 0.08,
		"approach": 0.13, "reach": 0.16, "grip": 0.30, "pull_up": 0.38, "settle": 0.10,
		"soft_collision": 0.18, "hard_collision": 0.39, "cloud_summon": -0.11}.get(state, 0.0)) if enabled else 0.0, blend)
	step_phase += dt * (10.0 if state == "run" else 6.8) * gait
	if not enabled:
		cursor = Vector2.ZERO
	if enabled and state=="look_around":
		cursor=Vector2(sin(now*9)*0.77,0.32)
	if enabled and state in ["reach","grip","pull_up","cloud_summon"]:
		cursor=Vector2(0,0.42)
	look = look.lerp(cursor.limit_length(1), blend)
	var breathe := sin(now * 2.4) * 0.019 if enabled else 0.0
	var nod := sin(now * 11) * 0.09 if enabled and state in ["happy", "petted"] else 0.0
	var sign := -1.0 if legacy else 1.0
	_pose("head", Vector3(look.y * 0.15 + posture * 0.6 + nod, look.x * -0.25 * sign, look.x * 0.09), blend)
	_pose("leftEye", Vector3(look.y * 0.13, look.x * -0.13 * sign, 0), blend)
	_pose("rightEye", Vector3(look.y * 0.13, look.x * -0.13 * sign, 0), blend)
	_pose("spine", Vector3(posture * sign + breathe, 0.02 * sin(step_phase) * gait, 0.012 * sin(now * 1.7)), blend)
	_pose("chest", Vector3(breathe, 0.04 * sin(step_phase) * gait, look.x * 0.025), blend)
	var arm_lift := 0.0
	if enabled and not seated:
		arm_lift = float({"happy": 0.65, "working": 0.32, "thinking": 0.48}.get(state, 0.0))
	for side in ["left", "right"]:
		var side_sign := -1.0 if side == "left" else 1.0
		var swing := sin(step_phase) * gait * side_sign
		var wave := sin(now*14)*0.22 if state=="happy" and side=="right" and enabled and not seated else 0.0
		var relax := 0.16 if state=="petted" and enabled else 0.0
		_pose(side + "UpperArm", Vector3(swing * -0.24 - relax, 0, (arm_lift+wave) * side_sign * sign), blend)
		_pose(side + "LowerArm", Vector3(-swing * 0.12 - 0.13 - absf(wave)*1.7, side_sign * arm_lift * 0.24, 0), blend)
		_pose(side + "UpperLeg", Vector3((swing * 0.27 + stance * 1.04) * sign, 0, stance * side_sign * 0.05), blend)
		var tuck := 0.0
		if enabled and state in ["dragged","thrown","falling","landing","hard_collision"]:
			tuck=clampf(0.13+motion.length()/2100,0.13,0.64)
		_pose(side + "LowerLeg", Vector3((maxf(0, -swing) * 0.27 - stance * 1.10 + tuck) * sign, 0, 0), blend)
		_pose(side + "Foot",Vector3((-stance*0.23-tuck*0.22)*sign,0,0),blend)
	var hips := int(roles["hips"])
	var hip_rest: Vector3 = starting_positions[hips]
	hip_rest.y += (-stance * 0.12 + breathe * 0.14 - posture * 0.03) * height
	skeleton.set_bone_pose_position(hips, skeleton.get_bone_pose_position(hips).lerp(hip_rest, blend))
	_gesture(now,dt,enabled,seated,impact,motion)
	var exposure := motion.limit_length(700.0) / 700.0 if hair and enabled else Vector2.ZERO
	secondary_velocity += ((exposure - secondary_motion) * 35.0 - secondary_velocity * 10.0) * dt
	secondary_motion = (secondary_motion + secondary_velocity * dt).limit_length(1.0)
	for i in secondary.size():
		var bone := secondary[i]
		var rest: Quaternion = rotations.get(bone, Quaternion.IDENTITY)
		var drift := 0.015 * sin(now * 4 + i * 0.7) if enabled and hair else 0.0
		var bone_name := String(skeleton.get_bone_name(bone)).to_lower()
		var cloth := 0.20 if "skirtfront" in bone_name and bone not in skirt_roots else 0.0
		var movement := Quaternion.from_euler(Vector3((secondary_motion.y * 0.16 + drift - stance*cloth) * sign, 0, secondary_motion.x * 0.225))
		skeleton.set_bone_pose_rotation(bone, (rest * movement).normalized())
	for bone in skirt_roots:
		var rest: Quaternion = rotations[bone]
		var vector := Vector3((stance*0.67+secondary_motion.y*0.09)*sign,0,secondary_motion.x*0.14)
		skeleton.set_bone_pose_rotation(bone,(rest*Quaternion.from_euler(vector)).normalized())
	var blink_phase := fmod(now + sin(now * 0.37) * 0.7, 4.9)
	var blink := 1.0 - clampf(absf(blink_phase - 4.72) / 0.12, 0, 1)
	if state in ["petted", "sleepy"]:
		blink = maxf(blink, 0.9 if state == "petted" else 0.73)
	var target_face := Vector2(0.65 if state in ["happy","petted"] else 0, 0.45 if state in ["warning","dragged","hard_collision"] else 0)
	face = face.lerp(target_face if enabled else Vector2.ZERO, blend)
	_morph("blink", blink if enabled else 0)
	_morph("happy", face.x)
	_morph("warning", face.y)

func _gesture(now: float, dt: float, enabled: bool, seated: bool, impact: String, motion: Vector2) -> void:
	var active := seated or enabled and state in ["dragged","thrown","falling","soft_collision","hard_collision",
		"approach","reach","grip","pull_up","cloud_summon","landing","recovering"]
	var target_weight := 0.94 if active else 0.0
	gesture_weight=lerpf(gesture_weight,target_weight,1-exp(-9*dt))
	if active:
		gesture_state="seated" if seated else state
	if gesture_weight<0.02:
		return
	var torso := world_bone("chest" if roles.has("chest") else "spine")
	var hips := world_bone("hips")
	for side in ["left","right"]:
		if not roles.has(side+"Hand") or not roles.has(side+"LowerArm"):
			continue
		var shoulder := world_bone(side+"UpperArm")
		var side_sign := signf(shoulder.x-torso.x)
		var gesture := Vector3(side_sign*0.135,-0.10,0.15)
		match gesture_state:
			"seated":
				gesture=hips-torso+Vector3(side_sign*0.117,0.081,0.16)
				if enabled and state=="happy":
					gesture.y+=sin(now*8)*0.024
			"dragged","thrown","falling":
				gesture=Vector3(side_sign*0.22-clampf(motion.x/4800,-0.13,0.13),-0.09+clampf(absf(motion.x)/2800,0,0.18),0.20)
			"approach":
				gesture=Vector3(side_sign*0.17,-0.25,0.11)
			"reach","grip","pull_up":
				var vertical := -0.04 if gesture_state=="reach" else -0.15 if gesture_state=="grip" else -0.21
				gesture=Vector3(side_sign*0.135,vertical,0.29)
			"cloud_summon":
				gesture=Vector3(side_sign*(0.14+sin(now*8)*0.035),-0.07+sin(now*8)*0.065,0.27)
			"soft_collision","hard_collision":
				var toward := -1.0 if "left" in impact else 1.0 if "right" in impact else 0.0
				gesture=Vector3(side_sign*0.08+toward*0.07,0.16 if "top" in impact else 0.05,0.16)
			"landing","recovering":
				gesture=Vector3(side_sign*0.27,-0.22,0.19)
		_solve_arm(side,torso+gesture,Vector3(side_sign*0.65,-1.0,0.05),gesture_weight)

func _solve_arm(side: String, target_world: Vector3, outward_world: Vector3, weight: float) -> void:
	var upper := int(roles[side+"UpperArm"])
	var lower := int(roles[side+"LowerArm"])
	var hand := int(roles[side+"Hand"])
	var shoulder := skeleton.get_bone_global_pose(upper).origin
	var elbow := skeleton.get_bone_global_pose(lower).origin
	var wrist := skeleton.get_bone_global_pose(hand).origin
	var a := shoulder.distance_to(elbow)
	var b := elbow.distance_to(wrist)
	var goal := skeleton.to_local(target_world)-shoulder
	if minf(a,b)<0.001 or goal.length_squared()<0.000001:
		return
	var axis := goal.normalized()
	var reach := clampf(goal.length(),absf(a-b)+0.001,a+b-0.001)
	var along := (a*a-b*b+reach*reach)/(2.0*reach)
	var outward := skeleton.global_transform.basis.inverse()*outward_world
	var pole := (outward-axis*outward.dot(axis)).normalized()
	var next_elbow := shoulder+axis*along+pole*sqrt(maxf(0,a*a-along*along))
	_rotate_chain(upper,elbow-shoulder,next_elbow-shoulder,weight)
	elbow=skeleton.get_bone_global_pose(lower).origin
	wrist=skeleton.get_bone_global_pose(hand).origin
	_rotate_chain(lower,wrist-elbow,shoulder+axis*reach-elbow,weight)

func _rotate_chain(bone: int, current: Vector3, desired: Vector3, weight: float) -> void:
	if minf(current.length_squared(),desired.length_squared())<0.000001:
		return
	var parent := skeleton.get_bone_parent(bone)
	var basis := skeleton.get_bone_global_pose(parent).basis.orthonormalized().inverse() if parent>=0 else Basis.IDENTITY
	var rotation := skeleton.get_bone_pose_rotation(bone)
	var change := Quaternion((basis*current).normalized(),(basis*desired).normalized())
	skeleton.set_bone_pose_rotation(bone,rotation.slerp((change*rotation).normalized(),weight))

func set_edition(enabled: bool) -> void:
	if midnight!=null and midnight.visible==enabled:
		return
	if enabled and midnight==null:
		# Derive an outfit scene from the loaded rig. Source VRM bytes stay intact.
		midnight=BoneAttachment3D.new()
		midnight.bone_idx=int(roles["hips"])
		skeleton.add_child(midnight)
		var metal := StandardMaterial3D.new()
		metal.albedo_color=Color("#ab9cc9")
		metal.metallic=0.54
		metal.roughness=0.32
		var gem := StandardMaterial3D.new()
		gem.albedo_color=Color("#735de3")
		gem.emission_enabled=true
		gem.emission=Color("#502f9c")
		gem.emission_energy_multiplier=0.28
		var clasp := TorusMesh.new()
		clasp.inner_radius=0.024
		clasp.outer_radius=0.034
		clasp.rings=14
		clasp.ring_segments=10
		var stone := BoxMesh.new()
		stone.size=Vector3(0.031,0.031,0.013)
		_mount_detail(clasp,metal,Vector3(0,0.096,0.11),Vector3(PI/2,0,0))
		_mount_detail(stone,gem,Vector3(0,0.096,0.121),Vector3(0,0,PI/4))
		for mesh in meshes:
			for surface in mesh.mesh.get_surface_count():
				var original := mesh.get_active_material(surface) as StandardMaterial3D
				if original==null or not "cloth" in (original.resource_name+" "+mesh.mesh.surface_get_name(surface)).to_lower():
					continue
				var tint := original.duplicate() as StandardMaterial3D
				tint.albedo_color *= Color(0.82,0.76,1.0)
				midnight_materials[[mesh,surface]]=[original,tint]
	if midnight!=null:
		midnight.visible=enabled
	for key in midnight_materials:
		var mesh: MeshInstance3D=key[0]
		mesh.set_surface_override_material(key[1],midnight_materials[key][int(enabled)])

func _mount_detail(mesh: PrimitiveMesh, material: Material, at: Vector3, angle: Vector3) -> void:
	var part := MeshInstance3D.new()
	part.mesh=mesh
	part.material_override=material
	part.position=at
	part.rotation=angle
	midnight.add_child(part)
