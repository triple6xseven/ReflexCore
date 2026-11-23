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
	body.place(Vector2(-1000,410))
	options.mode="taskbar"
	for frame in range(1,601):
		if body.update(1.0/60,frame/60.0,desk,size,Vector2i.ZERO,options,bounds)=="sit":
			push_error("Taskbar mode sat without a window perch.")
			quit(1)
			return
	options.mode="roam"
	var original_x:float=body.position.x
	for frame in range(601,1201):
		body.update(1.0/60,frame/60.0,desk,size,Vector2i.ZERO,options,bounds)
	if body.position.x!=original_x:
		push_error("Roam moved without a usable window.")
		quit(1)
		return
	options.mode="windows"
	var background:=Rect2i(-1240,450,460,320)
	var focused:=Rect2i(-1010,410,520,480)
	bounds.assign([background,focused])
	var pose: String
	for frame in range(1201,1651):
		pose=body.update(1.0/60,frame/60.0,desk,size,Vector2i.ZERO,options,bounds,focused)
	if pose!="sit" or body.support!=focused:
		push_error("Window mode did not perch on the foreground window.")
		quit(1)
		return
	print("Companion behavior: standing taskbar, quiet roam and foreground-window perch passed.")
	quit(0)
