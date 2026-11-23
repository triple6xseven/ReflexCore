extends Node3D

const LOBES := [
	Vector3(-68,11,-10),Vector3(-45,4,-10),Vector3(-18,0,-13),
	Vector3(13,0,-13),Vector3(43,5,-10),Vector3(66,12,-10),
	Vector3(-54,18,13),Vector3(-21,22,12),Vector3(17,22,12),Vector3(51,19,13)
]
var sparks: Array[MeshInstance3D] = []
var upper_material: StandardMaterial3D
var lower_material: StandardMaterial3D
var spark_material: StandardMaterial3D
var last_alpha := -1.0

func _ready() -> void:
	var sphere := SphereMesh.new()
	sphere.radial_segments=16
	sphere.rings=8
	upper_material=_material(Color("#a0c7ee"))
	lower_material=_material(Color("#749ccf"))
	for i in LOBES.size():
		var puff := _part(sphere,upper_material if i<6 else lower_material)
		puff.position=Vector3(LOBES[i].x,-LOBES[i].y,LOBES[i].z)
		var width := 32.0 if i in [0,5] else 39.0
		puff.scale=Vector3(width,25 if i<6 else 26,28)
	var diamond := BoxMesh.new()
	diamond.size=Vector3(3,3,2)
	spark_material=_material(Color("#d1ebff"))
	for i in 6:
		var spark := _part(diamond,spark_material)
		spark.rotation.z=PI*0.25
		sparks.append(spark)

func _material(tint: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color=tint
	material.transparency=BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
	return material

func _part(mesh: PrimitiveMesh,material: Material) -> MeshInstance3D:
	var part := MeshInstance3D.new()
	part.mesh=mesh
	part.material_override=material
	part.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(part)
	return part

func show_at(camera: Camera3D,center: Vector2,zoom: float,alpha: float,clock: float,view_height: float) -> void:
	visible=alpha>0.015
	if not visible:
		return
	# The cloud is real scene geometry behind the avatar. The skirt and legs
	# can occlude it as they pass in front of the platform.
	position=camera.project_position(center+Vector2(-4*zoom,8*zoom),4.16)
	var world_pixel := camera.size/maxf(view_height,1)
	scale=Vector3.ONE*world_pixel*zoom*lerpf(0.74,1.0,alpha)
	if alpha!=last_alpha:
		upper_material.albedo_color.a=alpha*0.92
		lower_material.albedo_color.a=alpha*0.87
		spark_material.albedo_color.a=alpha*0.8
		last_alpha=alpha
	for i in sparks.size():
		var phase := fmod(clock*0.7+i*0.39,1.0)
		sparks[i].position=Vector3(cos(i*2.4+phase)*72,phase*27-13,13)
		sparks[i].scale=Vector3.ONE*maxf(0.1,sin(phase*PI))
