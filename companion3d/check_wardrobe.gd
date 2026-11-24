extends SceneTree
const Wardrobe = preload("res://wardrobe.gd")
const Rig = preload("res://avatar_rig.gd")
var failed := 0

func _initialize() -> void:
	call_deferred("_verify")

func _verify() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("Pass the local companion directory after --.")
		quit(2)
		return
	var base := args[0].path_join("wardrobe")
	var manifest: Variant = JSON.parse_string(FileAccess.get_file_as_string(base.path_join(Wardrobe.MANIFEST)))
	if not manifest is Dictionary or manifest.get("schema") != Wardrobe.SCHEMA:
		push_error("Build the local wardrobe kit before running this check.")
		quit(2)
		return
	var count := 0
	for outfit in manifest.parts.outfit:
		for hair in manifest.parts.hair:
			for head in manifest.parts.head:
				for stockings in [false,true]:
					var keys := Wardrobe.choices(manifest,{"custom_outfit":outfit,"custom_hair":hair,"custom_head":head})
					var rig := Rig.new()
					if keys.is_empty() or not rig.load_bytes(Wardrobe.assemble(base,keys,stockings)):
						push_error("Import failed: %s %s %s %s / %s" % [outfit,hair,head,stockings,rig.error])
						failed += 1
						continue
					if rig.meshes.size()!=3 or rig.expression_binds<2 or rig.roles.size()!=19:
						push_error("Missing mesh, expressions or joints")
						failed += 1
					if outfit=="zxc" and rig.window_drape.size()!=1:
						push_error("Missing ZXC drape")
						failed += 1
					root.add_child(rig.scene)
					for tick in 45:
						rig.animate(1.0/60,tick/60.0,"sit",Vector2.ZERO,Vector2.ZERO,true,true,true)
					if not rig.world_bone("head").is_finite():
						push_error("Invalid animated head projection")
						failed += 1
					rig.free_scene()
					count += 1
	print("%d wardrobe permutations imported and posed. %d failed." % [count,failed])
	quit(0 if failed==0 and count>0 else 2)
