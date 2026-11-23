extends Node2D

var fade := 0.0
var phase := 0.0

func show_at(center: Vector2, zoom: float, alpha: float, clock: float) -> void:
	visible=alpha>0.01
	if not visible:
		return
	position=center+Vector2(0,8*zoom)
	scale=Vector2.ONE*zoom*lerpf(0.7,1.0,alpha)
	fade=alpha
	phase=clock
	queue_redraw()

func _draw() -> void:
	# Soft lobes and a cool rim under the seat. This stays on the overlay canvas.
	var lobes := [Vector3(-50,4,18),Vector3(-31,1,23),Vector3(-9,-1,23),
		Vector3(16,1,22),Vector3(39,6,20),Vector3(54,9,13)]
	draw_set_transform(Vector2.ZERO,0,Vector2(1,0.49))
	for lobe: Vector3 in lobes:
		draw_circle(Vector2(lobe.x,lobe.y+12),lobe.z+6,Color(0.36,0.49,0.9,fade*0.105),true,-1,true)
	for lobe: Vector3 in lobes:
		draw_circle(Vector2(lobe.x,lobe.y+7),lobe.z,Color(0.38,0.51,0.79,fade*0.27),true,-1,true)
		draw_circle(Vector2(lobe.x,lobe.y+1),lobe.z*0.89,Color(0.56,0.79,1,fade*0.36),true,-1,true)
	draw_set_transform(Vector2.ZERO)
	for i in 7:
		var t := fmod(phase*0.9+i*0.31,1.0)
		var p := Vector2(cos(i*2.4+t)*73,sin(i*2.4)*11-27*t)
		var shine := Color(0.66,0.84,1,fade*sin(t*PI)*0.78)
		draw_line(p+Vector2(0,-3.5),p+Vector2(0,3.5),shine,1.25,true)
		draw_line(p+Vector2(-2.5,0),p+Vector2(2.5,0),shine,1,true)
