extends RefCounted

const AtelierToon = preload("res://atelier_toon.gdshader")
const ZxcLegwear = preload("res://zxc_legwear.gdshader")
const LEGWEAR_COLORS := {
	"dark": Color("#241b30"), "black": Color("#211e26"), "white": Color("#f8f7f4"), "lilac": Color("#bc9de3"),
	"plum": Color("#673573"), "burgundy": Color("#642943")
}
const LEGWEAR_COVERAGE := {5: .24, 10: .36, 15: .48, 20: .59, 30: .76, 40: .93}
const LEGWEAR_MATERIALS := ["stocking knit", "stocking cuff", "midnight stocking feet", "lunar stocking", "lunar stocking welt"]
const LEGWEAR_CUFFS := ["stocking cuff", "lunar stocking welt"]
const SHEER_SKIN := Color("#efb7ab")

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
var atelier := false
var refined := false
var window_drape: Array = []
var legwear_surfaces: Array = []
var legwear_style := ""
var grip_fingers := {}
var curled_hands := {}
var drape_weight := 0.0
var ledge_drape := 0.0
var zxc := false
var nocturne := false
var long_drape := false
var sole_y := 0.0
var attentive := 0.0
var surprise := 0.0
var error := ""
var license_data := {}
var expression_binds := 0
var triangle_count := 0
var state := "idle"
var stance := 0.0
var seat_forward := Vector3.FORWARD
var seat_right := Vector3.RIGHT
var hover_drift := Vector2.ZERO
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
var wrist_targets := {}
var elbow_targets := {}
var sit_elapsed := 0.0
var leg_motion := 0.0
const FAMILIES := {"petted":"pat","face_smile":"smile","happy":"happy","dragged":"drag",
	"thrown":"flight","falling":"flight","hard_collision":"impact","soft_collision":"impact",
	"landing":"land","recovering":"land","thinking":"think","working":"work",
	"reach":"climb","grip":"climb","pull_up":"climb"}
enum CloudPose { REST, CROSS, SIDE, TUCK }
const CLOUD_POSE_SECONDS := 4.8
const CLOUD_SEQUENCE := [CloudPose.REST, CloudPose.CROSS, CloudPose.SIDE, CloudPose.CROSS,
	CloudPose.REST, CloudPose.CROSS, CloudPose.SIDE, CloudPose.TUCK]
const CLOUD_PREVIEW_SEQUENCE := [CloudPose.REST, CloudPose.CROSS, CloudPose.SIDE,
	CloudPose.CROSS, CloudPose.TUCK]
var turns := {}
var family := ""
var alternate := false
var surface := ""
var alternate_seat := false
var reaction_time := 0.0
var window_clock := 0.0
var crossed := 0.0
var cross_direction := -1.0
var cloud_clock := 0.0
var cloud_visit := -1
var hug_progress := 0.0
var knee_hug := 0.0
var side_sit := 0.0

func _take_turn(key: String) -> bool:
	var second := bool(turns.get(key,false))
	turns[key] = not second
	return second

func _select_variant(next: String, seated: bool, cloudy: bool, dt: float, enabled: bool, touch: bool) -> void:
	var key := str(FAMILIES.get(next,"")) if enabled else ""
	if key != family or (touch and key in ["pat","smile","happy"]):
		family = key
		alternate = key != "" and _take_turn(key)
		reaction_time = 0
	reaction_time += dt
	var seat := ("cloud" if cloudy else "window") if seated and enabled else ""
	if seat != surface:
		if seat=="cloud":
			cloud_visit=(cloud_visit+1)%CLOUD_SEQUENCE.size()
		cloud_clock=0.0
		surface = seat
		alternate_seat = seat != "" and _take_turn(seat)


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
	if bytes.size() != size:
		error = "invalid_glb"
		return false
	return load_bytes(bytes)

func load_bytes(bytes: PackedByteArray) -> bool:
	var size := bytes.size()
	if size < 24 or size > MAX_BYTES or bytes.decode_u32(0) != 0x46546c67 or bytes.decode_u32(4) != 2 or bytes.decode_u32(8) != size:
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
	var title := str(license_data.get("title",""))
	zxc=legacy and title=="ZXC"
	nocturne=legacy and title in ["Lumen - ReflexCompanion Midnight Nocturne","Lumen - ReflexCompanion Lunar Temptation","Lumen - ReflexCompanion Velvet Enchantress","Lumen - ReflexCompanion Velvet Bloom","ZXC"]
	long_drape=title in ["Lumen - ReflexCompanion Velvet Enchantress","Lumen - ReflexCompanion Velvet Bloom","ZXC"]
	refined=nocturne or legacy and title=="Lumen - ReflexCompanion Midnight Atelier Refined"
	sole_y=_measure_sole()
	atelier=refined or legacy and title=="Lumen - ReflexCompanion Midnight Atelier"
	if atelier:
		_apply_atelier_materials()
	if zxc:
		for mesh in meshes:
			var index := mesh.find_blend_shape_by_name("WindowDrape")
			if index>=0:
				window_drape.append([mesh,index])
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
	for bone in skirt_roots:
		starting_positions[bone] = skeleton.get_bone_pose_position(bone)
	for side in ["left","right"]:
		_lower_arm(side)
		var chain := []
		for digit in ["index","middle","ring","little"]:
			for joint in [1,2]:
				var prefix: String = "jbip"+side.left(1)+digit
				var bone := int(bone_name_ids.get(prefix+str(joint),-1))
				var child := int(bone_name_ids.get(prefix+str(joint+1),-1))
				if bone>=0 and child>=0:
					chain.append([bone,child,skeleton.get_bone_pose_rotation(bone),.28 if joint==1 else .36])
		grip_fingers[side]=chain
	_find_seat_axes()
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
			if int(primitive.get("mode", 4)) == 4:
				var count_id := index_id if index_id >= 0 and index_id < accessors.size() else index
				triangle_count += int(accessors[count_id].get("count", 0)) / 3
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
		if display.right(1) in ["0","1","2"] and ("skirtfront" in display or "skirtside" in display or long_drape and "skirtback" in display):
			skirt_roots.append(i)
	for bone in candidates:
		if secondary.size() >= 22:
			break
		if bone >= 0 and not roles.values().has(bone) and bone not in secondary:
			secondary.append(bone)

func _measure_sole() -> float:
	var low := INF
	for mesh in meshes:
		if not (String(mesh.name)+" "+mesh.mesh.resource_name).to_lower().contains("body"):
			continue
		for surface in mesh.mesh.get_surface_count():
			var arrays := mesh.mesh.surface_get_arrays(surface)
			var points: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
			var indices: Variant=arrays[Mesh.ARRAY_INDEX]
			if indices is PackedInt32Array and not indices.is_empty():
				for index in indices:
					low=minf(low,points[index].y)
			else:
				for point in points:
					low=minf(low,point.y)
	return low if is_finite(low) else bottom

func _apply_atelier_materials() -> void:
	var converted := {}
	for mesh in meshes:
		for surface in mesh.mesh.get_surface_count():
			var original := mesh.get_active_material(surface) as StandardMaterial3D
			if original == null:
				continue
			var name := original.resource_name.to_lower()
			var profile := -1.0
			if "hairback" in name:
				continue
			elif "_hair_" in name or name.begins_with("bloom hair") or "nocturne ear" in name or name in ["lunar pearlescent hair","lunar lilac hair"]:
				profile = 1.0
			elif "_skin" in name or "midnight barefoot" in name:
				profile = 0.0
			elif "nickel" in name or "amethyst" in name:
				profile = 3.0
			elif name in ["fitted top","tailored shorts","violet piping","graphite belt","corset panel",
					"woven harness","harness piping","high collar","shorts side panel","stocking cuff",
					"stocking knit","midnight stocking feet","nocturne satin","nocturne piping","nocturne strap","lunar silk","lunar panel","lunar seam","lunar cuff","lunar liner","lunar stocking","lunar stocking welt","velvet velvet","velvet silk fold","velvet embroidery", "bloom velvet", "bloom chiffon", "bloom piping", "bloom petal"]:
				profile = 2.0
			if profile < 0.0:
				continue
			if not converted.has(original):
				var material := ShaderMaterial.new()
				material.shader = AtelierToon
				if original.albedo_texture != null:
					material.set_shader_parameter("fabric_texture", original.albedo_texture)
				material.set_shader_parameter("base_tint", original.albedo_color)
				material.set_shader_parameter("profile", profile)
				material.set_shader_parameter("refined", refined)
				material.set_shader_parameter("alpha_cut", 0.44 if profile == 1.0 else 0.15)
				converted[original] = material
			mesh.set_surface_override_material(surface, converted[original])

func set_legwear(stocking_asset: bool, den: int, color: String) -> void:
	var style := "%d-%s" % [den,color] if stocking_asset else ""
	if style==legwear_style:
		return
	legwear_style=style
	if legwear_surfaces.is_empty():
		for mesh in meshes:
			for surface in mesh.mesh.get_surface_count():
				var source := mesh.mesh.surface_get_material(surface) as StandardMaterial3D
				if source==null:
					continue
				var name := source.resource_name.to_lower()
				var atlas := zxc and name=="zxc painted satin"
				if not atlas and name not in LEGWEAR_MATERIALS:
					continue
				var original := mesh.get_surface_override_material(surface)
				var variant := ShaderMaterial.new()
				if atlas:
					variant.shader=ZxcLegwear
					variant.set_shader_parameter("fabric_texture", source.albedo_texture)
				else:
					variant.shader=AtelierToon
					variant.set_shader_parameter("profile", 4.0)
					variant.set_shader_parameter("refined", refined)
				legwear_surfaces.append([mesh,surface,original,variant,atlas,name in LEGWEAR_CUFFS])
	var customized := stocking_asset and (den!=40 or color!="dark")
	var fabric: Color = LEGWEAR_COLORS.get(color, LEGWEAR_COLORS.dark)
	var coverage: float = LEGWEAR_COVERAGE.get(den, LEGWEAR_COVERAGE[40])
	var knit := SHEER_SKIN.lerp(fabric,coverage)
	# The folded top is denser and has a distinct edge even on near-black fabric.
	var welt := knit.lerp(Color("#ffffff") if color=="white" else fabric,.60)
	if color!="white":
		welt=welt.lightened(.115 if color=="black" else .082)
	for record in legwear_surfaces:
		var variant: ShaderMaterial = record[3]
		if customized:
			if record[4]:
				variant.set_shader_parameter("stocking_tint", knit)
				variant.set_shader_parameter("welt_tint", welt)
			else:
				variant.set_shader_parameter("base_tint", welt if record[5] else knit)
		record[0].set_surface_override_material(record[1], variant if customized else record[2])

func _expression_key(name: String) -> String:
	var key := _normalize(name)
	if atelier and key == "surprised":
		return "surprised"
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
			var preset := str(value.get("presetName", ""))
			if atelier and preset == "fun":
				continue
			var key := _expression_key(str(value.get("name", "")) if preset == "unknown" else preset)
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

func ear_anchors() -> PackedVector3Array:
	if not nocturne:
		return PackedVector3Array()
	var bone := int(roles["head"])
	var transform := skeleton.get_bone_global_pose(bone)*skeleton.get_bone_global_rest(bone).affine_inverse()
	return PackedVector3Array([
		skeleton.to_global(transform*Vector3(-.145,1.885,.006)),
		skeleton.to_global(transform*Vector3(.145,1.885,.006))
	])

func _morph(key: String, value: float) -> void:
	if absf(float(last_expression.get(key, -1)) - value) < 0.02:
		return
	last_expression[key] = value
	for binding in expressions.get(key, []):
		var mesh: MeshInstance3D = binding[0]
		mesh.set_blend_shape_value(binding[1], value * binding[2])

func _cross_phrase(seconds: float) -> float:
	# Lift, hold, then trace the same path back to the neutral seat.
	return smoothstep(5.0,6.4,seconds)*(1.0-smoothstep(10.5,12.0,seconds))

func _update_seated_variants(dt: float, window_cycle: bool, cloud_cycle: bool, preview: bool) -> void:
	window_clock=window_clock+dt if window_cycle else 0.0
	var cross_target := _cross_phrase(fmod(window_clock,12.0))
	var cloud_pose := CloudPose.REST
	if cloud_cycle:
		cloud_clock+=dt
		var segment := int(cloud_clock/CLOUD_POSE_SECONDS)
		cloud_pose=CLOUD_PREVIEW_SEQUENCE[segment%CLOUD_PREVIEW_SEQUENCE.size()] if preview else CLOUD_SEQUENCE[(cloud_visit+segment)%CLOUD_SEQUENCE.size()]
	var beat := fmod(cloud_clock,CLOUD_POSE_SECONDS)
	if cloud_pose==CloudPose.CROSS:
		cross_target=_cross_phrase(lerpf(5.0,12.0,beat/CLOUD_POSE_SECONDS))
	if cross_target>0.0 and crossed==0.0:
		cross_direction=-cross_direction
	crossed=cross_target
	# Each cloud variation releases back to the ordinary seat before the next.
	var phrase := smoothstep(.08,1.38,beat)*(1-smoothstep(3.08,4.58,beat))
	var shift := 1-exp(-6.0*dt)
	hug_progress=lerpf(hug_progress,phrase if cloud_pose==CloudPose.TUCK else 0.0,shift)
	knee_hug=smoothstep(.04,.93,hug_progress)
	side_sit=lerpf(side_sit,phrase if cloud_pose==CloudPose.SIDE else 0.0,shift)

func animate(dt: float, now: float, next: String, cursor: Vector2, motion: Vector2, hair: bool, enabled: bool, seated: bool=false, impact: String="", cloudy: bool=false, window_swing := false, sit_style := "still", intensity := 1.0, touch := false, preview := false) -> void:
	_select_variant(next,seated,cloudy,dt,enabled,touch)
	state = next
	var blend := 1.0 - exp(-10.0 * dt)
	var variations := enabled and seated and sit_style!="still"
	_update_seated_variants(dt,variations and not cloudy and window_swing,variations and cloudy,preview)
	var swing_active := enabled and seated and (window_swing or refined and cloudy) and sit_style!="still"
	attentive=lerpf(attentive,1.0 if refined and seated and state=="attentive" else 0.0,blend)
	sit_elapsed=sit_elapsed+dt if swing_active else 0.0
	leg_motion=lerpf(leg_motion,smoothstep(0.2,1.3,sit_elapsed)*intensity,blend)
	hover_drift=hover_drift.lerp((motion/180.0).limit_length(1) if enabled and state=="hover" else Vector2.ZERO,1-exp(-4*dt))
	var moving := state in ["walk", "run"]
	gait = lerpf(gait, 1.0 if moving and enabled else 0.0, blend)
	stance = lerpf(stance, 1.0 if seated else 0.0, blend)
	posture = lerpf(posture, float({"thinking": 0.16, "working": 0.08, "sleepy": 0.24, "falling": -0.13,
		"dragged": -0.14, "thrown": -0.24, "landing": 0.28, "recovering": 0.12, "petted": 0.08,
		"approach": 0.13, "reach": 0.16, "grip": 0.30, "pull_up": 0.38, "settle": 0.10,
		"hover": -0.06, "stand_up": 0.17, "soft_collision": 0.18, "hard_collision": 0.39, "cloud_summon": -0.11, "attentive": 0.10}.get(state, 0.0)) if enabled else 0.0, blend)
	step_phase += dt * (10.0 if state == "run" else 6.8) * gait
	if not enabled:
		cursor = Vector2.ZERO
	if enabled and state=="look_around":
		cursor=Vector2(sin(now*9)*0.77,0.32)
	if enabled and state in ["reach","grip","pull_up","cloud_summon"]:
		cursor=Vector2(0,0.42)
	look = look.lerp(cursor.limit_length(1), blend)
	var breathe := sin(now * 2.4) * 0.019 if enabled else 0.0
	if refined and seated and enabled:
		breathe += sin(now * 1.06) * 0.012
	var nod := sin(now * 11) * 0.09 if enabled and state in ["happy", "petted"] else 0.0
	var sign := -1.0 if legacy else 1.0
	if enabled and state=="tickled":
		nod+=0.048*sin(now*15)
	var tilt := .14*cos(reaction_time*2.1) if alternate and family in ["pat","smile","think","happy"] else 0.0
	_pose("head", Vector3(look.y * 0.15 + posture * 0.6 + nod, look.x * -0.25 * sign, look.x * 0.09 + tilt), blend)
	_pose("leftEye", Vector3(look.y * 0.13, look.x * -0.13 * sign, 0), blend)
	_pose("rightEye", Vector3(look.y * 0.13, look.x * -0.13 * sign, 0), blend)
	_pose("spine", Vector3(posture * sign + breathe, 0.02 * sin(step_phase) * gait, 0.012 * sin(now * 1.7)-hover_drift.x*.13), blend)
	_pose("chest", Vector3(breathe+.12*knee_hug*sign, 0.04 * sin(step_phase) * gait+.16*side_sit+.13*crossed*cross_direction, look.x * 0.025+.06*side_sit-.07*crossed*cross_direction), blend)
	var arm_lift := 0.0
	if enabled and not seated:
		arm_lift = float({"happy": 0.18, "working": 0.32, "thinking": 0.48}.get(state, 0.0))
	for side in ["left", "right"]:
		var side_sign := -1.0 if side == "left" else 1.0
		var swing := sin(step_phase) * gait * side_sign
		var wave := sin(now*8)*0.075 if state=="happy" and side=="right" and enabled and not seated else 0.0
		var relax := 0.16 if state=="petted" and enabled else 0.0
		_pose(side + "UpperArm", Vector3(swing * -0.24 - relax, 0, (arm_lift+wave) * side_sign * sign), blend)
		_pose(side + "LowerArm", Vector3(-swing * 0.12 - 0.13 - absf(wave)*1.7, side_sign * arm_lift * 0.24, 0), blend)
		_pose(side + "Hand", Vector3.ZERO, blend)
		var tuck := 0.0
		if enabled and state in ["dragged","thrown","falling","landing","hard_collision"]:
			tuck=clampf(0.13+motion.length()/2100,0.13,0.64)
		elif enabled and state=="hover":
			tuck=.26+side_sign*(.13+.13*hover_drift.x)+sin(now*2.35+side_sign)*.075+.1*maxf(0,-hover_drift.y)
			swing=.32*sin(now*2.35+side_sign)+.38*side_sign*hover_drift.x
		_seat_leg(side,side_sign,swing,tuck,sign,blend,cloudy,sit_style)
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
		if bone in skirt_roots:
			continue
		var cloth := 0.05 if "skirtfront" in String(skeleton.get_bone_name(bone)).to_lower() else 0.0
		var movement := Quaternion.from_euler(Vector3((secondary_motion.y * 0.16 + drift - stance*cloth) * sign, 0, secondary_motion.x * 0.225))
		skeleton.set_bone_pose_rotation(bone, (rest * movement).normalized())
	ledge_drape=lerpf(ledge_drape,1.0 if seated and not cloudy else 0.0,blend)
	for bone in skirt_roots:
		_drape_skirt(bone,blend)
	if not window_drape.is_empty():
		var weight := lerpf(drape_weight,stance if not cloudy else 0.0,blend)
		if absf(weight-drape_weight)>.0001:
			drape_weight=weight
			for bind in window_drape:
				bind[0].set_blend_shape_value(bind[1],weight)
	var blink_phase := fmod(now + sin(now * 0.37) * 0.7, 4.9)
	var blink := 1.0 - clampf(absf(blink_phase - 4.72) / 0.12, 0, 1)
	if state in ["petted", "sleepy"]:
		blink = maxf(blink, 0.9 if state == "petted" else 0.73)
	var target_face := Vector2(0.65 if state in ["happy","petted"] else 0, 0.45 if state in ["warning","dragged","hard_collision"] else 0)
	if enabled and state in ["tickled","face_smile"]:
		target_face.x=0.79 if state=="tickled" else 0.68
		blink=maxf(blink,0.72 if state=="tickled" else 0.30)
	if refined and enabled:
		match state:
			"petted":
				blink=maxf(blink,0.83)
				target_face.x=0.39
			"attentive":
				target_face.x=0.22
			"thinking":
				blink=maxf(blink,0.16+0.06*sin(now*2.1))
			"happy":
				target_face.x=0.50
			"sit","cloud_sit":
				target_face.x=0.10
	if alternate and family in ["pat","smile","happy"]:
		target_face.x=.68+.12*cos(reaction_time*3)
		blink=maxf(blink,.55)
	if atelier:
		var startled := enabled and state in ["dragged", "thrown", "hard_collision"]
		surprise = lerpf(surprise, 0.45 if startled else 0.0, blend)
		if startled:
			target_face.y = 0.0
		elif state == "curious":
			target_face.x = 0.18
		_morph("surprised", surprise)
	face = face.lerp(target_face if enabled else Vector2.ZERO, blend)
	_morph("blink", blink if enabled else 0)
	_morph("happy", face.x)
	_morph("warning", face.y)

func _drape_skirt(bone: int, blend: float) -> void:
	var children := skeleton.get_bone_children(bone)
	if children.is_empty():
		return
	var joint := children[0]
	var rest_pose := skeleton.get_bone_global_rest(bone)
	var direction := skeleton.get_bone_global_rest(joint).origin-rest_pose.origin
	if direction.length_squared()<0.000001:
		return
	var display := String(skeleton.get_bone_name(bone)).to_lower()
	var front := "skirtfront" in display
	var lateral := signf(rest_pose.origin.dot(seat_right))
	if display.begins_with("j_sec_l_"):
		lateral=-1.0
	elif display.begins_with("j_sec_r_"):
		lateral=1.0
	var outward := seat_right*lateral
	var flow := seat_forward*(0.86 if front else 0.52)+Vector3.DOWN*(0.55 if front else 0.85)
	var segment := display.right(1).to_int()
	if segment==0 and front:
		flow=seat_forward*0.98+Vector3.DOWN*0.12
	elif segment>0:
		flow=flow.lerp(Vector3.DOWN,0.42 if segment==1 else 0.82)
	if front and knee_hug>0:
		var draped := seat_forward*(.74 if segment==0 else .94)+Vector3.UP*(.86 if segment==0 else -.16)
		flow=flow.lerp(draped,knee_hug)

	if not front:
		flow+=outward*0.46
		if nocturne:
			var back := "skirtback" in display
			flow=Vector3.DOWN+outward*(.20 if back else .38)-seat_forward*(.24 if back else .12)
			if long_drape and not zxc:
				var over_edge := outward*.56+Vector3.DOWN*.55+seat_forward*(1.26 if back else .78)
				flow=flow.lerp(over_edge,ledge_drape)
				if segment==1:
					# Slide the loose panel over the lip while the waist remains fixed.
					var start: Vector3=starting_positions[bone]
					var offset := (seat_forward*(.075 if back else .046)+outward*.032)*ledge_drape*stance
					skeleton.set_bone_pose_position(bone,start+_parent_basis(bone).inverse()*offset)
	var from := (_parent_basis(bone,true).inverse()*direction).normalized()
	var to := (_parent_basis(bone).inverse()*flow).normalized()
	var rest: Quaternion=rotations[bone]
	var target := (Quaternion(from,to)*rest).normalized()
	var sway := Vector3(secondary_motion.y*.065,0,secondary_motion.x*.09)
	_blend_joint(bone,sway,target,blend)

func _find_seat_axes() -> void:
	var left := skeleton.get_bone_global_rest(int(roles["leftUpperLeg"])).origin
	var right := skeleton.get_bone_global_rest(int(roles["rightUpperLeg"])).origin
	seat_right=(right-left).slide(Vector3.UP).normalized()
	var forward := Vector3.FORWARD if legacy else Vector3.BACK
	if roles.has("leftEye") and roles.has("rightEye"):
		var a := skeleton.get_bone_global_rest(int(roles["leftEye"])).origin
		var b := skeleton.get_bone_global_rest(int(roles["rightEye"])).origin
		var skull := skeleton.get_bone_global_rest(int(roles["head"])).origin
		var projected := ((a+b)*0.5-skull).slide(Vector3.UP).slide(seat_right)
		if projected.length()>0.005:
			forward=projected.normalized()
	seat_forward=forward

func _seat_leg(side: String,side_sign: float,swing: float,tuck: float,sign: float,blend: float,cloudy: bool,sit_style: String) -> void:
	var upper := side+"UpperLeg"
	var lower := side+"LowerLeg"
	var foot := side+"Foot"
	var standing_thigh := Vector3(swing*0.27*sign,0,0)
	var standing_shin := Vector3((maxf(0,-swing)*0.27+tuck)*sign,0,0)
	var standing_foot := Vector3(-tuck*0.22*sign,0,0)
	if stance<0.015 or not roles.has(lower) or not roles.has(foot):
		_pose(upper,standing_thigh,blend)
		_pose(lower,standing_shin,blend)
		_pose(foot,standing_foot,blend)
		return
	var knee_drop := (0.16 if cloudy else 0.12)+side_sign*0.035
	var spread := 0.13 if atelier and not cloudy else 0.07
	if refined:
		spread=lerpf(0.085 if cloudy else 0.142,0.19,attentive)
		knee_drop+=0.045*attentive
	if nocturne:
		var relaxed_asymmetry := (0.048 if side_sign>0 else -0.02)*(1.0-attentive)
		knee_drop += relaxed_asymmetry if not cloudy else relaxed_asymmetry*0.38
		spread=lerpf(spread,0.106,0.3)
	var thigh := seat_forward+seat_right*side_sign*spread-Vector3.UP*knee_drop
	var phase := sit_elapsed*1.9 + side_sign*0.95
	var stretch := pow(maxf(0.0,sin(sit_elapsed*0.58+side_sign*1.57)),12)*0.32 if sit_style=="relaxed" else 0.0
	var rhythm := sin(phase)*0.13+stretch
	if refined:
		rhythm=sin(phase)*(.095 if cloudy else .14)+sin(phase*.43+side_sign*1.5)*.045+stretch
		rhythm*=lerpf(1.0,0.4,attentive)
	var reach := 0.09+side_sign*0.02
	if nocturne:
		reach += (0.15 if side_sign>0 else 0.04)*leg_motion*(1.0-attentive) if not cloudy else -0.055
		rhythm += sin(phase*.28+side_sign)*0.036
	if alternate_seat and sit_style!="still":
		rhythm += (.22 if cloudy else .29)*pow(.5+.5*sin(sit_elapsed*1.5+side_sign*1.9),3)
	var shin := Vector3.DOWN+seat_forward*(reach+leg_motion*rhythm)
	var leg_hug := smoothstep(.12 if side=="right" else .02,.98 if side=="right" else .86,hug_progress)
	thigh=thigh.lerp(seat_forward*.62+Vector3.UP*.84+seat_right*.12*side_sign,leg_hug)
	shin=shin.lerp(Vector3.DOWN-seat_forward*.42,smoothstep(0,.75,leg_hug))
	thigh=thigh.lerp(seat_forward+seat_right*(.44+side_sign*.14)-Vector3.UP*.19,side_sit)
	shin=shin.lerp(Vector3.DOWN+seat_right*.19+seat_forward*(.48 if side_sign>0 else -.18),side_sit)
	if crossed>0:
		# Lift before moving across the supporting thigh. Reverse the path to release.
		var across := smoothstep(.25,1.0,crossed)
		var upper_leg := side_sign*cross_direction<0
		var across_seat := seat_right*cross_direction
		var lift := (.42*crossed+.21*sin(PI*crossed)) if upper_leg else -.08*crossed
		thigh+=Vector3.UP*lift+across_seat*(.61 if upper_leg else -.09)*across
		shin+=seat_forward*(.32 if upper_leg else -.09)*crossed+across_seat*(.18 if upper_leg else -.08)*across
	_orient_segment(upper,lower,thigh,standing_thigh,blend)
	_orient_segment(lower,foot,shin,standing_shin,blend)
	var ankle := int(roles[foot])
	var basis := _parent_basis(ankle)
	var neutral := skeleton.get_bone_global_rest(ankle).basis.orthonormalized()
	if atelier and (not cloudy or refined):
		var tip := leg_motion*(0.08+0.1*sin(phase-0.48)) + (0.11 if cloudy else 0.16)
		neutral = Basis(seat_right, tip) * neutral
	if zxc and alternate_seat and sit_style=="relaxed":
		# On the second visit, extend one foot and trace a small arc with the ankle.
		var beat := fmod(sit_elapsed+(.0 if side=="left" else 3.4),6.8)
		var extension := smoothstep(.2,1.25,beat)*(1.0-smoothstep(1.65,2.7,beat))
		extension*=leg_motion*(1.0-knee_hug)*(1.0-crossed)
		neutral=Basis(seat_right,-.24*extension)*Basis(seat_forward,.115*side_sign*extension)*neutral
	var seated_rotation := (basis.inverse()*neutral).get_rotation_quaternion()
	_blend_joint(ankle,standing_foot,seated_rotation,blend)

func _parent_basis(bone: int, rest := false) -> Basis:
	var parent := skeleton.get_bone_parent(bone)
	if parent<0:
		return Basis.IDENTITY
	return (skeleton.get_bone_global_rest(parent) if rest else skeleton.get_bone_global_pose(parent)).basis.orthonormalized()

func _orient_segment(role: String, child: String, direction: Vector3, idle: Vector3, blend: float) -> void:
	var bone := int(roles[role])
	var joint := int(roles[child])
	var rest_axis := skeleton.get_bone_global_rest(joint).origin-skeleton.get_bone_global_rest(bone).origin
	if rest_axis.length_squared()<0.000001:
		_pose(role,idle,blend)
		return
	var from := (_parent_basis(bone,true).inverse()*rest_axis).normalized()
	var to := (_parent_basis(bone).inverse()*direction).normalized()
	var rest_rotation: Quaternion=rotations[bone]
	_blend_joint(bone,idle,(Quaternion(from,to)*rest_rotation).normalized(),blend)

func _blend_joint(bone: int, idle: Vector3, target: Quaternion, blend: float) -> void:
	var rest: Quaternion=rotations[bone]
	var standing := (rest*Quaternion.from_euler(idle)).normalized()
	var pose := standing.slerp(target,stance)
	skeleton.set_bone_pose_rotation(bone,skeleton.get_bone_pose_rotation(bone).slerp(pose,blend))

func _gesture(now: float, dt: float, enabled: bool, seated: bool, impact: String, motion: Vector2) -> void:
	var active := seated or enabled and state in ["walk","run","dragged","thrown","falling","soft_collision","hard_collision",
		"approach","reach","grip","pull_up","stand_up","cloud_summon","hover","landing","recovering"]
	active = active or (alternate and family in ["think","work","pat","happy","smile"])
	var target_weight := 0.94 if active else 0.0
	gesture_weight=lerpf(gesture_weight,target_weight,1-exp(-9*dt))
	if active:
		gesture_state="seated" if seated else state
	if gesture_weight<0.02:
		wrist_targets.clear()
		elbow_targets.clear()
		for side in ["left","right"]:
			_curl_grip(side,Vector3.ZERO,0.0)
		return
	var torso := world_bone("chest" if roles.has("chest") else "spine")
	var hips := world_bone("hips")
	var frame := skeleton.global_basis.orthonormalized()
	var inverse_frame := frame.transposed()
	var forward := frame*seat_forward
	for side in ["left","right"]:
		if not roles.has(side+"Hand") or not roles.has(side+"LowerArm"):
			continue
		var shoulder := world_bone(side+"UpperArm")
		var side_sign := signf(shoulder.x-torso.x)
		var lateral := -1.0 if side=="left" else 1.0
		var outward := frame*seat_right*lateral
		var gesture := Vector3(side_sign*0.135,-0.10,0.15)
		var knee_grip := 0.0
		var grip_direction := Vector3.ZERO
		var grip_normal := Vector3.ZERO
		match gesture_state:
			"seated":
				var has_knee := roles.has(side+"LowerLeg")
				var knee := world_bone(side+"LowerLeg") if has_knee else Vector3.ZERO
				gesture=hips-torso+Vector3(side_sign*0.117,0.081,0.16)
				if atelier:
					var support := hips+outward*(.222 if long_drape else .203)-forward*.038+Vector3.DOWN*.026
					gesture=support-torso
					if has_knee:
						var thigh := world_bone(side+"UpperLeg")
						var lap := thigh.lerp(knee,.43)+outward*.037+Vector3.UP*.065
						var brace := crossed if lateral==cross_direction else 0.0
						if side=="right":
							brace=maxf(brace,side_sit)
						gesture=(lap.lerp(support,brace)-torso).lerp(lap-torso,attentive*.32)
				if hug_progress>0 and has_knee and roles.has(side+"Foot"):
					var shin := (world_bone(side+"Foot")-knee).normalized()
					var ahead := forward.slide(shin).normalized()
					var pad := knee+shin*.055+ahead*.049+outward*.018
					var wrist_target := pad+outward*.057-shin*.026
					grip_direction=(pad-wrist_target).normalized()
					grip_normal=(-ahead-outward*.22).normalized()
					knee_grip=smoothstep(.22 if side=="left" else .32,.88 if side=="left" else .98,hug_progress)
					gesture=gesture.lerp(wrist_target-torso,knee_grip)
					gesture+=outward*.044*sin(PI*knee_grip)
				if not atelier and crossed>0 and lateral==cross_direction:
					gesture=gesture.lerp(hips-torso+outward*.23-forward*.038+Vector3.DOWN*.025,crossed)
				if enabled and state=="happy":
					gesture.y+=sin(now*8)*0.024
			"dragged","thrown","falling":
				gesture=Vector3(side_sign*0.22-clampf(motion.x/4800,-0.13,0.13),-0.09+clampf(absf(motion.x)/2800,0,0.18),0.20)
			"approach":
				gesture=Vector3(side_sign*0.17,-0.25,0.11)
			"reach","grip","pull_up":
				var vertical := -0.04 if gesture_state=="reach" else -0.15 if gesture_state=="grip" else -0.21
				gesture=Vector3(side_sign*0.135,vertical,0.29)
			"walk","run":
				var stride := -sin(step_phase)*lateral*gait
				var arm_length := shoulder.distance_to(world_bone(side+"LowerArm"))
				arm_length += world_bone(side+"LowerArm").distance_to(world_bone(side+"Hand"))
				var reach := arm_length*(.21 if gesture_state=="run" else .135)
				var clearance := arm_length*(.19 if long_drape else .125)
				var wrist := shoulder+outward*clearance+forward*(arm_length*.075+stride*reach)
				wrist+=Vector3.DOWN*(arm_length*(.95-.035*maxf(0,stride)))
				gesture=wrist-torso
			"cloud_summon":
				gesture=outward*.16+forward*.18+Vector3.DOWN*(.16+.027*sin(now*6))
			"hover":
				var sway := sin(now*2.4+side_sign*.65)*.035
				var lead := side_sign*hover_drift.x
				gesture=outward*(.23+sway+.08*lead)+forward*(.09+.09*lead)+Vector3.DOWN*(.19-sway-.10*lead+.065*hover_drift.y)
			"stand_up":
				gesture=hips-torso+outward*.20+forward*.075+Vector3.UP*.06
			"soft_collision","hard_collision":
				var toward := -1.0 if "left" in impact else 1.0 if "right" in impact else 0.0
				gesture=Vector3(side_sign*0.08+toward*0.07,0.16 if "top" in impact else 0.05,0.16)
			"landing","recovering":
				gesture=Vector3(side_sign*0.27,-0.22,0.19)
		if alternate:
			var beat := sin(reaction_time*4.0)
			match family:
				"think","pat","happy","smile","work":
					if not seated:
						gesture=hips-torso+outward*.16+forward*.075
					if family=="work":
						gesture=outward*.12+forward*(.21+.035*beat*side_sign)+Vector3.DOWN*(.08+.024*beat*side_sign)
					elif side=="right":
						var lift := .11 if family=="think" else -.025
						gesture=outward*.075+forward*.15+Vector3.UP*(lift+.022*beat)
				"drag","flight":
					gesture+=outward*.055+Vector3.UP*(.065*side_sign)+forward*.025
				"impact","land":
					gesture+=outward*.035+Vector3.UP*(.085 if side=="left" else -.018)
				"climb":
					gesture+=Vector3.UP*(.055*side_sign)+forward*(.03*side_sign)
		var pole := Vector3(side_sign*0.65,-1.0,0.05)
		if gesture_state in ["walk","run"]:
			pole=outward*(.60 if long_drape else .42)-forward
		elif gesture_state=="cloud_summon":
			pole=outward*.38+Vector3.DOWN-forward*.2
		elif atelier and (seated or gesture_state=="stand_up"):
			pole=outward*.68+Vector3.DOWN-forward*.34
		if knee_grip>0.0:
			pole=pole.lerp(outward*.95+Vector3.DOWN*.45-forward*.15,knee_grip)
		# Keep targets in rig space, so turning the whole avatar carries both arms.
		var wrist_goal := skeleton.to_local(torso+gesture)
		var elbow_goal := inverse_frame*pole
		var follow := 1.0-exp(-lerpf(17.0,28.0,knee_grip)*dt)
		var previous_wrist: Vector3 = wrist_targets.get(side,bone_position(side+"Hand"))
		var elbow: Vector3 = elbow_targets.get(side,elbow_goal)
		wrist_targets[side]=previous_wrist.lerp(wrist_goal,follow)
		elbow_targets[side]=elbow.lerp(elbow_goal,follow)
		_solve_arm(side,wrist_targets[side],elbow_targets[side],lerpf(gesture_weight,1.0,knee_grip))
		var hand := int(roles[side+"Hand"])
		var finger := int(bone_name_ids.get("jbip"+side.left(1)+"middle1",-1))
		if finger >= 0:
			var wrist := bone_position(side+"Hand")
			var forearm := (wrist-bone_position(side+"LowerArm")).normalized()
			var arm_side := seat_right*lateral
			if gesture_state=="seated" and atelier:
				var palm := (seat_forward+arm_side*.13+Vector3.DOWN*.31).normalized()
				_orient_hand(side,hand,finger,palm,Vector3.DOWN,gesture_weight*.86)
			elif atelier and gesture_state in ["walk","run","cloud_summon","stand_up","hover"]:
				var palm := (forearm+arm_side*.09+Vector3.DOWN*.20).normalized()
				_orient_hand(side,hand,finger,palm,-arm_side,gesture_weight*.76)
			if knee_grip>0.0:
				_orient_hand(side,hand,finger,inverse_frame*grip_direction,inverse_frame*grip_normal,knee_grip)
		_curl_grip(side,inverse_frame*grip_normal,knee_grip)


func _curl_grip(side: String, normal: Vector3, amount: float) -> void:
	var curling := amount>0.001
	if not curling and not curled_hands.get(side,false):
		return
	curled_hands[side]=curling
	for joint in grip_fingers[side]:
		var bone: int = joint[0]
		var child: int = joint[1]
		skeleton.set_bone_pose_rotation(bone,joint[2])
		if curling:
			var segment := skeleton.get_bone_global_pose(child).origin-skeleton.get_bone_global_pose(bone).origin
			var axis := segment.normalized()
			var into_palm := normal.slide(axis).normalized()
			var flex: float = joint[3]*amount
			_rotate_chain(bone,axis,axis*cos(flex)+into_palm*sin(flex),1.0)


func _orient_hand(side: String, hand: int, finger: int, aim: Vector3, normal: Vector3, amount: float) -> void:
	var thumb := int(bone_name_ids.get("jbip"+side.left(1)+"thumb1",-1))
	if thumb<0:
		return
	var palm := skeleton.get_bone_global_pose(hand).origin
	var fingers := (skeleton.get_bone_global_pose(finger).origin-palm).normalized()
	var thumb_side := (skeleton.get_bone_global_pose(thumb).origin-palm).slide(fingers).normalized()
	if thumb_side.length_squared()<0.5:
		return
	var rest := skeleton.get_bone_global_rest(hand).origin
	var straight := skeleton.get_bone_global_rest(finger).origin-rest
	var rest_thumb := skeleton.get_bone_global_rest(thumb).origin-rest
	var handedness := signf(straight.cross(rest_thumb).dot(Vector3.DOWN))
	var across := normal.cross(aim).normalized()*handedness
	if across.length_squared()<0.5:
		return
	var from := Basis(fingers,thumb_side,fingers.cross(thumb_side))
	var to := Basis(aim,across,aim.cross(across))
	var parent := _parent_basis(hand)
	var change := (parent.inverse()*to*from.transposed()*parent).get_rotation_quaternion()
	var pose := skeleton.get_bone_pose_rotation(hand)
	skeleton.set_bone_pose_rotation(hand,pose.slerp((change*pose).normalized(),amount))


func _solve_arm(side: String, target: Vector3, outward: Vector3, weight: float) -> void:
	var upper := int(roles[side+"UpperArm"])
	var lower := int(roles[side+"LowerArm"])
	var hand := int(roles[side+"Hand"])
	var shoulder := skeleton.get_bone_global_pose(upper).origin
	var elbow := skeleton.get_bone_global_pose(lower).origin
	var wrist := skeleton.get_bone_global_pose(hand).origin
	var a := shoulder.distance_to(elbow)
	var b := elbow.distance_to(wrist)
	var goal := target-shoulder
	if minf(a,b)<0.001 or goal.length_squared()<0.000001:
		return
	var axis := goal.normalized()
	var reach := clampf(goal.length(),absf(a-b)+0.001,a+b-0.001)
	var along := (a*a-b*b+reach*reach)/(2.0*reach)
	var pole := outward.slide(axis)
	if pole.length_squared()<0.0001:
		pole=(elbow-shoulder).slide(axis)
	pole=pole.normalized()
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
