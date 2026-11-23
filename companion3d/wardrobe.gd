extends RefCounted

const MANIFEST := "manifest.json"
const SCHEMA := "reflexcore.wardrobe.v1"
const TABLES := ["accessors", "bufferViews", "materials", "textures", "images", "samplers"]
const SLOTS := ["outfit", "hair", "head"]
const EDITIONS := ["nocturne", "lunar", "velvet", "zxc"]
const NODE_SLOTS := [1, 165, 0]
const PART_LIMIT := 24 * 1024 * 1024

static func choices(manifest: Dictionary, options: Dictionary) -> PackedStringArray:
	if manifest.get("schema") != SCHEMA or not manifest.get("parts") is Dictionary:
		return []
	var generation: String = str(manifest.get("generation", ""))
	if generation.length() != 20:
		return []
	for character in generation:
		if character not in "0123456789abcdef":
			return []
	var selected := PackedStringArray([generation])
	for slot in SLOTS:
		var edition := str(options.get("custom_" + slot, "lunar"))
		var available: Variant = manifest.parts.get(slot)
		if edition not in EDITIONS or not available is Dictionary or not available.has(edition):
			return []
		selected.append(edition)
	return selected

static func assemble(folder: String, selected: PackedStringArray, stockings: bool) -> PackedByteArray:
	var generation := folder.path_join(selected[0])
	var rig := _read_part(generation.path_join("rig-" + selected[1] + ".part"))
	if rig.is_empty():
		return []
	var doc: Dictionary = rig.doc
	var binary: PackedByteArray = rig.data
	doc.meshes = []
	for i in SLOTS.size():
		var suffix := "-stockings" if i == 0 and stockings else ""
		var part := _read_part(generation.path_join(SLOTS[i] + "-" + selected[i + 1] + suffix + ".part"))
		if part.is_empty():
			return []
		var materialized := _append(doc, part.doc, binary.size())
		doc.nodes[NODE_SLOTS[i]].mesh = doc.meshes.size()
		doc.nodes[NODE_SLOTS[i]].skin = 0
		doc.meshes.append(materialized)
		binary.append_array(part.data)
	doc.buffers = [{"byteLength": binary.size()}]
	var tree := JSON.stringify(doc).to_utf8_buffer()
	while tree.size() % 4:
		tree.append(32)
	var bytes := PackedByteArray()
	bytes.resize(20)
	bytes.encode_u32(0, 0x46546c67)
	bytes.encode_u32(4, 2)
	bytes.encode_u32(8, 28 + tree.size() + binary.size())
	bytes.encode_u32(12, tree.size())
	bytes.encode_u32(16, 0x4e4f534a)
	bytes.append_array(tree)
	var header := PackedByteArray()
	header.resize(8)
	header.encode_u32(0, binary.size())
	header.encode_u32(4, 0x004e4942)
	bytes.append_array(header)
	bytes.append_array(binary)
	return bytes

static func _read_part(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > PART_LIMIT:
		return {}
	var bytes := file.get_buffer(file.get_length())
	if bytes.size() < 28 or bytes.decode_u32(0) != 0x46546c67 or bytes.decode_u32(4) != 2 or bytes.decode_u32(8) != bytes.size():
		return {}
	var size := bytes.decode_u32(12)
	if size < 2 or size > 1024 * 1024 or 28 + size > bytes.size():
		return {}
	if bytes.decode_u32(16) != 0x4e4f534a or bytes.decode_u32(24 + size) != 0x004e4942 or bytes.decode_u32(20 + size) != bytes.size() - 28 - size:
		return {}
	var value: Variant = JSON.parse_string(bytes.slice(20, 20 + size).get_string_from_utf8())
	if not value is Dictionary:
		return {}
	for table in TABLES:
		var rows: Variant = value.get(table)
		if not rows is Array or rows.size() > 4096:
			return {}
		for row in rows:
			if not row is Dictionary:
				return {}
	for view in value.bufferViews:
		var start := int(view.get("byteOffset", -1))
		var length := int(view.get("byteLength", -1))
		if start < 0 or length < 0 or start + length > bytes.size() - 28 - size:
			return {}
	if path.get_file().begins_with("rig-"):
		if not value.get("nodes") is Array or value.nodes.size() != 167:
			return {}
		for index in NODE_SLOTS:
			if not value.nodes[index] is Dictionary:
				return {}
	else:
		var models: Variant = value.get("meshes")
		if not models is Array or models.size() != 1 or not models[0] is Dictionary:
			return {}
		var primitives: Variant = models[0].get("primitives")
		if not primitives is Array or primitives.is_empty() or primitives.size() > 96:
			return {}
		for primitive in primitives:
			if not primitive is Dictionary or not primitive.get("attributes") is Dictionary:
				return {}
			var targets: Variant = primitive.get("targets", [])
			if not targets is Array or targets.size() > 8:
				return {}
			for target in targets:
				if not target is Dictionary:
					return {}
	return {"doc": value, "data": bytes.slice(28 + size)}

static func _append(doc: Dictionary, part: Dictionary, offset: int) -> Dictionary:
	var base := {}
	for table in TABLES:
		base[table] = doc[table].size()
		doc[table].append_array(part[table])
	for view in part.bufferViews:
		view.byteOffset = int(view.byteOffset) + offset
	for field in ["accessors", "images"]:
		for item in part[field]:
			item.bufferView = int(item.get("bufferView", -1)) + base.bufferViews
	for item in part.textures:
		item.source = int(item.get("source", -1)) + base.images
		if item.has("sampler"):
			item.sampler = int(item.sampler) + base.samplers
	for material in part.materials:
		for section in [material, material.get("pbrMetallicRoughness", {})]:
			if section is Dictionary:
				for key in section:
					if String(key).ends_with("Texture") and section[key] is Dictionary:
						section[key].index = int(section[key].get("index", -1)) + base.textures
	var mesh: Dictionary = part.meshes[0]
	for primitive in mesh.primitives:
		primitive.material = int(primitive.get("material", -1)) + base.materials
		if primitive.has("indices"):
			primitive.indices = int(primitive.indices) + base.accessors
		for fields in [primitive.attributes] + primitive.get("targets", []):
			for key in fields:
				fields[key] = int(fields[key]) + base.accessors
	return mesh
