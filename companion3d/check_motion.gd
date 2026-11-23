extends SceneTree

const Motion = preload("res://desktop_motion.gd")

func _initialize() -> void:
	var desk := Rect2i(-1440, 0, 1440, 900)
	var size := Vector2i(320,480)
	var options := {"mode":"windows","physics":true,"gravity":900,"walk_speed":58}
	var bounds: Array[Rect2i] = [Rect2i(-1060,620,450,180)]
	var body = Motion.new()
	body.place(Vector2(-990,40))
	body.grab()
	body.release(Vector2(50,-64),true,0)
	for frame in range(1,151):
		body.update(1.0/60,frame/60.0,desk,size,Vector2i(-900,300),options,bounds)
	if body.falling or not body.supported or absf(body.position.y+size.y-25-620)>2:
		push_error("Throw failed to land at the window's top edge.")
		quit(1)
		return
	bounds[0].position.y += 14
	for frame in range(151,181):
		body.update(1.0/60,frame/60.0,desk,size,Vector2i(-900,300),options,bounds)
	if absf(body.position.y+size.y-25-634)>2:
		push_error("Support movement was not followed.")
		quit(1)
		return
	bounds.clear()
	for frame in range(181,301):
		body.update(1.0/60,frame/60.0,desk,size,Vector2i(-900,300),options,bounds)
	if body.falling or absf(body.position.y+size.y-25-897)>2:
		push_error("Closed support did not release the avatar to the work area floor.")
		quit(1)
		return
	body.grab()
	body.release(Vector2(-1000,-100),true,5)
	for frame in range(301,450):
		body.update(1.0/60,frame/60.0,desk,size,Vector2i(-900,300),options,bounds)
		if body.position.x<desk.position.x or body.position.x+size.x>desk.end.x:
			push_error("Throw crossed monitor bounds.")
			quit(1)
			return
	print("Companion physics: window landing, moving support, support removal and negative monitor coordinates passed.")
	quit(0)
