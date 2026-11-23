extends RefCounted

var position := Vector2.ZERO
var velocity := Vector2.ZERO
var held := false
var falling := false
var landing_at := -5.0
var rest_at := 0.0
var support := Rect2i()
var supported := false
var lock_until := 0.0
var active := Rect2i()
var active_seen := 0.0
var mode := ""
var last_position := Vector2.ZERO

func place(p: Vector2) -> void:
	position = p
	last_position = p
	velocity = Vector2.ZERO
	falling = false
	supported = false
	support = Rect2i()

func grab() -> void:
	held = true
	falling = false
	supported = false
	support = Rect2i()
	velocity = Vector2.ZERO

func drag_to(p: Vector2, observed: Vector2, dt: float) -> void:
	position = position.lerp(p, minf(dt * 40, 1))
	velocity = velocity.lerp(observed.limit_length(1000), minf(dt * 20, 1))

func release(push: Vector2, physics: bool, now: float) -> void:
	held = false
	falling = physics
	velocity = push.limit_length(1000) if physics else Vector2.ZERO
	lock_until = now + 3.2
	rest_at = now

func update(dt: float, now: float, desk: Rect2i, size: Vector2i, pointer: Vector2i, options: Dictionary, windows: Array[Rect2i], foreground := Rect2i()) -> String:
	var desired_mode: String = options.get("mode", "taskbar")
	if mode != desired_mode:
		mode = desired_mode
		supported = false
		lock_until = 0.0
	var margin := 5.0
	var foot := float(size.y) - 25.0
	var floor := float(desk.end.y) - 3
	var min_x := float(desk.position.x) + margin
	var max_x := maxf(min_x, float(desk.end.x-size.x) - margin)
	var min_y := float(desk.position.y) + margin
	if mode in ["windows","roam"] and not falling:
		# Logical motion uses the standing sole; the view lifts the overlay
		# by the sole-to-seat offset while perched.
		min_y -= size.y * 0.47
	var max_y := maxf(min_y, floor-foot)
	var sole_x := position.x + size.x*0.5
	if held:
		_last(dt)
		return "dragged"

	if supported and support.has_area():
		if not lock_until > 0.0 or options.get("physics", true):
			var follow := _matching(support,windows)
			if not follow.has_area() or not follow.grow(18).has_point(Vector2i(sole_x,follow.position.y)):
				supported=false
				falling=bool(options.get("physics",true))
				velocity=Vector2.ZERO
			else:
				support=follow
				position.y=lerpf(position.y,float(follow.position.y)-foot,minf(22*dt,1))

	if falling:
		# Semi-implicit integration with explicit step bound and swept foot crossing.
		var old_sole := position.y + foot
		velocity.y = minf(velocity.y + float(options.get("gravity",900)) * dt,1450.0)
		velocity.x *= exp(-1.1 * dt)
		position += velocity * dt
		if position.x < min_x or position.x > max_x:
			position.x = clampf(position.x,min_x,max_x)
			velocity.x *= -0.37
		if position.y < min_y:
			position.y = min_y
			velocity.y = maxf(0,velocity.y)
		var landed_at := floor
		var surface := Rect2i()
		var new_sole := position.y + foot
		var new_x := position.x + size.x * 0.5
		if velocity.y >= 0:
			for window in windows:
				if not _walkable(window,desk,new_x):
					continue
				var y := float(window.position.y)
				if old_sole <= y+2 and new_sole >= y and y < landed_at:
					landed_at = y
					surface = window
			if new_sole >= landed_at:
				position.y = landed_at-foot
				falling = false
				velocity = Vector2.ZERO
				supported = true
				support = surface
				landing_at = now
				rest_at = now
		_last(dt)
		return "falling" if falling else "landing"

	if now - landing_at < 0.23:
		_last(dt)
		return "landing"
	if now - landing_at < 0.48:
		_last(dt)
		return "recovering"

	position.x=clampf(position.x,min_x,max_x)
	position.y=clampf(position.y,min_y,max_y)
	if now < lock_until or mode=="stationary":
		_last(dt)
		return "idle"
	var path := position
	var walking := false
	var sitting := false
	match mode:
		"follow":
			var dx := float(pointer.x)-sole_x
			if absf(dx)>216:
				path.x = float(pointer.x)-float(size.x)*0.5-signf(dx)*165
			path.y = max_y
		"windows", "roam":
			# The tray supplies the active window first. Wait briefly before
			# changing targets, and leave the avatar parked between events.
			var target := _first_surface(windows,desk,size)
			if mode=="windows" and foreground.has_area():
				target=foreground if _perchable(foreground,desk,size) else Rect2i()
			if not target.has_area() and supported and _perchable(support,desk,size):
				target=support
			if active!=target and (not target.has_area() or active.intersection(target).get_area()<target.get_area()*0.72):
				active=target
				active_seen=now
				if target.has_area() and _matching(support,[target])!=target:
					supported=false
					support=Rect2i()
			if target.has_area() and now-active_seen>0.42:
				var low := maxf(min_x,float(target.position.x)+56-size.x*0.5)
				var high := minf(max_x,float(target.end.x)-56-size.x*0.5)
				path.x = clampf(position.x,low,high)
				var target_y:=float(target.position.y)-foot
				# Approach the surface horizontally before settling from above.
				if absf(path.x-position.x) < 5:
					path.y=target_y
					sitting = absf(position.y-target_y) < 2
				if sitting:
					supported=true
					support=target
			elif not target.has_area():
				path.y=max_y
		"taskbar":
			path.y=max_y
	var walk_speed := float(options.get("walk_speed",58))
	path.x=clampf(path.x,min_x,max_x)
	path.y=clampf(path.y,min_y,max_y)
	var travel:=path-position
	walking=absf(travel.x)>4
	position.x=move_toward(position.x,path.x,walk_speed*dt)
	position.y=move_toward(position.y,path.y, maxf(walk_speed,160)*dt)
	_last(dt)
	if walking:
		return "run" if walk_speed>120 else "walk"
	if sitting:
		return "sit"
	return "sleepy" if now-rest_at>100 else "idle"

func _last(dt: float) -> void:
	if not held and not falling:
		velocity=(position-last_position)/maxf(0.001,dt)
	last_position=position

func _walkable(window: Rect2i, desk: Rect2i, x: float) -> bool:
	return window.size.x>130 and window.size.y>80 and window.position.y>desk.position.y+190 and window.position.y<desk.end.y-14 and x>window.position.x+22 and x<window.end.x-22

func _matching(old: Rect2i, windows: Array[Rect2i]) -> Rect2i:
	for window in windows:
		if window==old:
			return window
	for window in windows:
		if window.intersection(old).get_area()>old.get_area()*0.72:
			return window
	return Rect2i()

func _perchable(window: Rect2i,desk: Rect2i,size: Vector2i) -> bool:
	return desk.intersection(window).size.x>150 && window.size.y>80 \
		and window.position.y>desk.position.y+size.y*0.53 \
		and window.position.y<desk.end.y-size.y*0.46

func _first_surface(windows: Array[Rect2i],desk: Rect2i,size: Vector2i) -> Rect2i:
	for window in windows:
		if _perchable(window,desk,size):
			return window
	return Rect2i()
