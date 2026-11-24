extends RefCounted

const STEP := 1.0 / 120.0
const SEAT_RATIO := 0.61
const SIDE_INSET := 0.22
const TOP_INSET := 0.09
const CLIMB_SECONDS := 0.94
const STAND_SECONDS := 0.42
var position := Vector2.ZERO
var velocity := Vector2.ZERO
var held := false
var falling := false
var landing_at := -5.0
var rest_at := 0.0
var drop_magnet_until := -1.0
var support := Rect2i()
var supported := false
var seated := false
var support_id := 0
var support_origin := Vector2i.ZERO
var support_at := 0.0
var support_speed := 0.0
var lock_until := 0.0
var mode := ""
var angle := 0.0
var angular_speed := 0.0
var impact := ""
const NO_WINDOW_EDGES: Array[Rect2i] = []
var impact_at := -5.0
var impact_speed := 0.0
var climb_progress := 0.0
var climb_origin := Vector2.ZERO
var climb_edge := Rect2i()
var climb_id := 0
var cloud_edge := 0.0
var cloud_since := -1.0
var cloud_alpha := 0.0
var cloud_seated := false
var cloud_deadline := 0.0
var cloud_x := 0.0
var cloud_collision_until := 0.0
var cloud_was_seat := false
var stand_until := 0.0
var cloud_trip := Vector2.INF
var ferry_edge := Rect2i()
var ferry_id := 0
var ferry_next_portal := false
var portal_time := 0.0
var portal_scale := 1.0
var ferry_until := 0.0
var next_cloud_trip := 0.0
var physics_time := 0.0
var operator_until := 0.0
var roam_until := 0.0
var roam_target := INF

func _end_ferry() -> void:
	ferry_edge=Rect2i()
	portal_time=0
	portal_scale=1

func place(p: Vector2) -> void:
	drop_magnet_until=-1.0
	_end_ferry()
	ferry_until=0
	position = p
	operator_until=0.0
	roam_until=0.0
	roam_target=INF
	held = false
	cloud_seated=false
	cloud_was_seat=false
	stand_until=0.0
	cloud_trip=Vector2.INF
	next_cloud_trip=0.0
	lock_until=0
	cloud_deadline=0
	velocity = Vector2.ZERO
	falling = false
	_clear_support()
	climb_progress = 0.0
	cloud_since = -1.0
	cloud_alpha = 0.0
	cloud_collision_until=0.0
	physics_time = 0.0

func _clear_support() -> void:
	supported = false
	seated = false
	support_id = 0
	support_speed=0.0
	support = Rect2i()

func interrupt(now: float, physics: bool) -> void:
	_end_ferry()
	stand_until=0.0
	cloud_trip=Vector2.INF
	operator_until=now+3.8
	roam_until=0.0
	roam_target=INF
	if climb_progress>0:
		climb_progress=0.0
		release(Vector2.ZERO,physics,now,0.18)
	if cloud_since>=0 and not cloud_seated:
		cloud_since=-1.0
		cloud_deadline=operator_until+0.8

func grab(now := 0.0, seat_y := 0.0) -> void:
	drop_magnet_until=-1.0
	_end_ferry()
	held = true
	stand_until=0.0
	cloud_trip=Vector2.INF
	falling = false
	_clear_support()
	climb_progress = 0.0
	if cloud_seated:
		cloud_edge=seat_y
		cloud_collision_until=now+1.5
	cloud_since = -1.0
	cloud_seated = false
	cloud_was_seat=false
	velocity = Vector2.ZERO
	angular_speed = 0.0

func drag_to(target: Vector2, observed: Vector2, dt: float) -> void:
	# Critically damped spring. The substeps keep the response stable at idle FPS.
	var remaining := minf(dt,0.05)
	while remaining > 0.00001:
		var step := minf(remaining,STEP)
		velocity += ((target-position)*410.0 - velocity*40.5)*step
		velocity = velocity.limit_length(1700)
		position += velocity*step
		remaining -= step
	angle = lerpf(angle,clampf(observed.x/3400.0,-0.23,0.23),1-exp(-9*dt))

func release(push: Vector2, physics: bool, now: float, recovery_delay := 1.4, magnetic_drop := false) -> void:
	drop_magnet_until=now+.13 if magnetic_drop and push.length_squared()<8100.0 else -1.0
	held = false
	impact_at=-5.0
	falling = physics
	velocity = push.limit_length(1500) if physics else Vector2.ZERO
	angular_speed = clampf(velocity.x/340.0,-3.0,3.0)
	physics_time = 0.0
	lock_until = now+recovery_delay
	cloud_deadline = now+recovery_delay+0.4
	rest_at = now

func update(dt: float, now: float, desk: Rect2i, size: Vector2i, pointer: Vector2i,
		options: Dictionary, windows: Array[Rect2i], foreground := Rect2i(), identities := {}, occupied := false) -> String:
	var desired_mode: String = options.get("mode","taskbar")
	if mode!=desired_mode:
		_end_ferry()
		var departing_seat := seated or cloud_seated
		if departing_seat and not held:
			if stand_until==0.0:
				stand_until=now+STAND_SECONDS
			if now<stand_until:
				return "stand_up"
		mode=desired_mode
		_clear_support()
		climb_progress=0.0
		_leave_cloud(size)
		lock_until=0
		roam_target=INF
		roam_until=0.0
		stand_until=0.0
		cloud_trip=Vector2.INF
		if departing_seat and not held:
			release(Vector2.ZERO,bool(options.get("physics",true)),now,.65)
	if seated:
		stand_until=0.0
	var foot := float(size.y)-25*float(size.y)/500
	var seat := size.y*SEAT_RATIO
	var floor := float(desk.end.y)-3
	# The body layout includes empty space beside and above the visible rig.
	var inset_x := size.x*SIDE_INSET
	var min_x := float(desk.position.x)-inset_x
	var max_x := maxf(min_x,float(desk.end.x-size.x)+inset_x)
	var top := float(desk.position.y)-size.y*TOP_INSET
	var bottom := maxf(top,floor-foot)
	var walk_windows := mode in ["windows","roam"]
	var real_physics: bool = options.get("physics",true)
	if not walk_windows or not options.get("magic",true):
		_end_ferry()
		cloud_trip=Vector2.INF
		cloud_collision_until=0
		_leave_cloud(size)
	cloud_alpha=move_toward(cloud_alpha,1.0 if (cloud_since>=0 and now-cloud_since>0.57 or now<cloud_collision_until) else 0.0,dt*3.8)
	if held:
		position.x=clampf(position.x,min_x,max_x)
		position.y=minf(position.y,bottom)
		if absf(position.x+size.x*0.5-cloud_x)>size.x*0.55:
			cloud_collision_until=0
		return "dragged"
	if supported and support.has_area():
		var updated := _follow(windows,identities)
		var origin := _origin(updated,identities)
		var change := Vector2(origin-support_origin)
		var moved_center := position.x+change.x+size.x*0.5
		var elapsed := clampf(now-support_at,0.036,0.24)
		if change!=Vector2.ZERO:
			support_speed=lerpf(support_speed,change.length()/elapsed,0.55)
		elif now-support_at>0.15:
			support_speed=0.0
		var can_follow := updated.has_area() and _fits(updated,desk,size) \
			and (seated or updated.position.y-foot>=top) \
			and moved_center>=updated.position.x+22 and moved_center<=updated.end.x-22 \
			and position.x+change.x>=min_x and position.x+change.x<=max_x
		if not can_follow or (real_physics and (change.length()>95 or support_speed>820 and change.length()>19)):
			_clear_support()
			release((change/elapsed*0.28).limit_length(260) if can_follow else Vector2.ZERO,real_physics,now)
		else:
			if change!=Vector2.ZERO or updated!=support:
				position.x += change.x
				support_at=now
			support=updated
			support_origin=origin
			position.y=float(support.position.y)-(seat if seated else foot)
			velocity=change/maxf(elapsed,dt)
			if seated:
				angle=move_toward(angle,0,dt*3)
				return "sit"
	var magnet := clampf(float(options.get("window_magnet",1.0)),0.5,2.0) if options.get("window_magnet_enabled",true) else 0.0
	if walk_windows and magnet>0 and now<drop_magnet_until:
		var perch := _drop_perch(windows,desk,size,seat,magnet)
		if perch.has_area():
			drop_magnet_until=-1.0
			falling=false
			velocity=Vector2.ZERO
			climb_edge=perch
			climb_id=_id(perch,identities)
			climb_origin=position
			return _climb(dt,now,perch,identities,seat,size)
	if falling:
		physics_time += minf(dt,0.05)
		while physics_time>=STEP and falling:
			physics_time-=STEP
			_fall_step(STEP,now,desk,size,windows if walk_windows else NO_WINDOW_EDGES,identities,foot,min_x,max_x,top,floor,float(options.get("gravity",900)))
		if falling and now-impact_at<0.26:
			return "hard_collision" if impact_speed>510 else "soft_collision"
		if falling:
			return "thrown" if now-rest_at<0.22 and velocity.length()>150 else "falling"
	angle=move_toward(angle,0,dt*3.5)
	if now-landing_at<0.25:
		return "landing"
	if now-landing_at<0.56:
		return "recovering"
	if cloud_seated and cloud_was_seat and now-landing_at<0.82:
		return "cloud_sit"
	if mode=="stationary":
		position=position.clamp(Vector2(min_x,top),Vector2(max_x,bottom))
		velocity=Vector2.ZERO
		return "idle"

	if mode=="hover":
		var cursor_gap := Vector2(pointer)-position-Vector2(size)*Vector2(.5,.45)
		var goal := position
		if not occupied and now>=operator_until and cursor_gap.length()>145:
			var advance := cursor_gap.limit_length(maxf(0,cursor_gap.length()-105))
			goal=position+advance
		var highest := maxf(top,bottom-size.y*.44)
		var lowest := maxf(highest,bottom-36)
		goal=goal.clamp(Vector2(min_x,highest),Vector2(max_x,lowest))
		_fly_to(goal,dt,160)
		return "hover"

	var target := Rect2i()
	if walk_windows and now>=maxf(lock_until,operator_until) and now>=roam_until:
		target=_reachable(windows,foreground if mode=="windows" else Rect2i(),desk,size,foot,seat,magnet)
	if climb_progress>0:
		var tracked := _climb_target(windows,identities)
		var shift := _origin(tracked,identities)-_origin(climb_edge,identities)
		var climb_center := position.x+size.x*0.5
		if not tracked.has_area() or shift.length()>38 or not _fits(tracked,desk,size) \
			or climb_center<tracked.position.x+24 or climb_center>tracked.end.x-24:
			climb_progress=0
			release(Vector2.ZERO,real_physics,now)
			return "falling" if falling else "recovering"
		return _climb(dt,now,tracked,identities,seat,size)
	if cloud_seated and now>=maxf(ferry_until,operator_until):
		if stand_until==0.0 and not ferry_edge.has_area() and not target.has_area() and magnet>0 and not occupied and now-cloud_since>2.2:
			var best := INF
			for edge in windows:
				var goal := _ferry_goal(edge,desk,size)
				var distance := position.distance_squared_to(goal)
				if goal.is_finite() and distance<best:
					best=distance
					ferry_edge=edge
					ferry_id=_id(edge,identities)
		if ferry_edge.has_area():
			var current := _nearest_segment(ferry_edge,ferry_id,windows,identities)
			var goal := _ferry_goal(current,desk,size)
			if goal.is_finite():
				ferry_edge=current
				cloud_trip=Vector2.INF
				if ferry_next_portal:
					portal_time+=dt
					portal_scale=1.0-smoothstep(0,.44,portal_time)+smoothstep(.50,1.0,portal_time)
					if portal_time>=.46:
						position=goal
					velocity=Vector2.ZERO
				else:
					_fly_to(goal,dt,260)
				cloud_x=position.x+size.x*.5
				cloud_edge=position.y+seat
				if (portal_time>=1.03 if ferry_next_portal else position.distance_to(goal)<2):
					position=goal
					ferry_next_portal=not ferry_next_portal
					_end_ferry()
					cloud_since=-1
					cloud_seated=false
					supported=true
					seated=true
					support=current
					support_id=_id(current,identities)
					support_origin=_origin(current,identities)
					support_at=now
					velocity=Vector2.ZERO
					return "sit"
				return "portal" if ferry_next_portal else "cloud_fly"
			_end_ferry()
			ferry_until=now+1.5
			cloud_since=now-.94
	if mode=="roam" and cloud_seated:
		var roam_center := position.x+size.x*.5
		var pointer_distance := pointer.x-roam_center
		if stand_until==0.0 and not cloud_trip.is_finite() and not occupied and not target.has_area() and now>=maxf(operator_until,next_cloud_trip) \
			and now-cloud_since>6.5 and absf(pointer_distance)>size.x*.66:
			var travel := signf(pointer_distance)*minf(size.x*.83,absf(pointer_distance)-size.x*.38)
			var end_x := clampf(position.x+travel,min_x,max_x)
			if absf(end_x-position.x)>45:
				cloud_trip=Vector2(end_x,clampf(position.y-size.y*.11,top,bottom))
				next_cloud_trip=now+24.0
		if cloud_trip.is_finite():
			_fly_to(cloud_trip,dt,132)
			cloud_x=position.x+size.x*.5
			cloud_edge=position.y+seat
			if position.distance_to(cloud_trip)<1.0:
				cloud_trip=Vector2.INF
				cloud_since=now-.93
			return "cloud_fly"

	# Commit to standing once it starts. A limb entering the hover area during
	# the transition cannot cancel the rise and restart it a frame later.
	var roam_departure := mode=="roam" and cloud_seated and (not occupied or stand_until>0.0) \
		and now>=operator_until and now-cloud_since>12.0
	if cloud_seated and (target.has_area() or roam_departure):
		if stand_until==0.0:
			stand_until=now+STAND_SECONDS
		if now<stand_until:
			return "stand_up"
	else:
		stand_until=0.0
	if target.has_area():
		if cloud_since>=0:cloud_deadline=now+1.25
		_leave_cloud(size)
		var center := position.x+size.x*0.5
		var desired_x := clampf(center,maxf(min_x+size.x*0.5,target.position.x+40),minf(max_x+size.x*0.5,target.end.x-40))-size.x*0.5
		if absf(desired_x-position.x)>3:
			_walk_to(desired_x,float(options.get("walk_speed",58)),dt)
			position.x=clampf(position.x,min_x,max_x)
			velocity.y=0.0
			return "run" if absf(velocity.x)>120 else "walk"
		climb_edge=target
		climb_id=_id(target,identities)
		climb_origin=position
		return _climb(dt,now,target,identities,seat,size)

	# Let Free Roam alternate a cloud rest with a short walk along the desk.
	if roam_departure:
		_leave_cloud(size)
		cloud_was_seat=false
		roam_until=now+6.0
		var visitor := clampf(float(pointer.x)-size.x*0.5,min_x,max_x)
		var distance := visitor-position.x
		# Take a short walk toward a distant visitor, leaving the pointer clear.
		var step := signf(distance)*minf(240,absf(distance)-105) if absf(distance)>145 else (145.0 if position.x<(min_x+max_x)*0.5 else -145.0)
		roam_target=clampf(position.x+step,min_x,max_x)
		release(Vector2.ZERO,real_physics,now,0.65)
		cloud_deadline=roam_until+4.0
		return "falling" if falling else "recovering"

	var wants_cloud: bool = walk_windows and options.get("magic",true) and now>=cloud_deadline 		and (cloud_seated or now>=maxf(operator_until,roam_until))
	if wants_cloud:
		if cloud_since<0:
			cloud_since=now
			position.x=clampf(position.x,min_x,max_x)
			cloud_x=position.x+size.x*0.5
			cloud_edge=clampf(position.y+seat+12,top+seat,maxf(top,bottom-24)+seat)
		var age := now-cloud_since
		if age<0.29:
			return "look_around"
		if age<0.93:
			return "cloud_summon"
		cloud_seated=true
		cloud_was_seat=false
		var bob := sin((age-0.93)*2.0)*3.0
		var compression := sin(minf(age-0.93,0.62)*PI/0.62)*7.0
		position.y=move_toward(position.y,cloud_edge+bob+compression-seat,80*dt)
		velocity=Vector2.ZERO
		return "cloud_sit"
	if cloud_since>=0:
		_leave_cloud(size)
	var old := position
	position.y=move_toward(position.y,bottom,150*dt)
	var walk_goal := position.x
	if mode=="follow" and absf(pointer.x-position.x-size.x*0.5)>216:
		var dx := pointer.x-position.x-size.x*0.5
		walk_goal=clampf(pointer.x-size.x*0.5-signf(dx)*165,min_x,max_x)
	if mode=="roam" and now<roam_until and now>=operator_until and is_finite(roam_target):
		walk_goal=roam_target
	if mode in ["follow","roam"]:
		_walk_to(walk_goal,float(options.get("walk_speed",58)),dt)
	position.x=clampf(position.x,min_x,max_x)
	velocity=(position-old)/dt
	return "walk" if absf(velocity.x)>5 else "sleepy" if now-rest_at>100 else "idle"

func _leave_cloud(size: Vector2i) -> void:
	if cloud_seated:
		cloud_x=position.x+size.x*.5
		cloud_edge=position.y+size.y*SEAT_RATIO
	cloud_since=-1.0
	cloud_seated=false

func _walk_to(goal: float, speed: float, dt: float) -> void:
	var distance := goal-position.x
	var acceleration := maxf(160.0,speed*5.0)
	var desired := signf(distance)*minf(speed,sqrt(2.0*acceleration*absf(distance)))
	velocity.x=move_toward(velocity.x,desired,acceleration*dt)
	var step := velocity.x*dt
	if step*distance>0.0 and absf(step)>=absf(distance):
		position.x=goal
		velocity.x=0.0
	else:
		position.x+=step

func _fly_to(goal: Vector2, dt: float, speed: float) -> void:
	var offset := goal-position
	var desired := (offset*3.5).limit_length(speed)
	velocity=velocity.lerp(desired,1.0-exp(-6.0*dt))
	if offset.length()<1.0 and velocity.length()<5.0:
		velocity=Vector2.ZERO
		return
	position+=velocity*dt
	angle=lerpf(angle,clampf(velocity.x/1050.0,-.14,.14),1.0-exp(-7.0*dt))

func _fall_step(dt: float, now: float, desk: Rect2i, size: Vector2i, windows: Array[Rect2i],
		identities: Dictionary, foot: float, min_x: float, max_x: float, top: float, floor: float, gravity: float) -> void:
	var old := position
	velocity.y=minf(velocity.y+gravity*dt,1450)
	velocity.x*=exp(-1.2*dt)
	position+=velocity*dt
	angular_speed*=exp(-2.6*dt)
	angle=clampf(angle+angular_speed*dt,-0.74,0.74)
	var hit_side := position.x<min_x or position.x>max_x
	# A release from above the ceiling re-enters naturally instead of snapping down.
	var hit_top := old.y>=top and position.y<top
	if hit_side or hit_top:
		var horizontal := "left" if position.x<min_x else "right"
		var recent := now-impact_at<=0.12
		var side := horizontal if hit_side else impact
		var corner := hit_top and (hit_side or recent and impact in ["left","right"])
		corner=corner or hit_side and recent and impact=="top"
		impact="top_"+side if corner else horizontal if hit_side else "top"
		impact_speed=velocity.length()
		impact_at=now
		if hit_side:
			position.x=clampf(position.x,min_x,max_x)
			velocity.x*= -0.32 if impact_speed>180 else 0
			angular_speed=clampf(velocity.x/180,-2,2)
		if hit_top:
			position.y=top
			velocity.y=absf(velocity.y)*0.20
		if corner:
			var inward := 1.0 if side=="left" else -1.0
			var rebound := clampf(impact_speed*0.38,55,330)
			velocity=Vector2(inward*maxf(absf(velocity.x),rebound),maxf(absf(velocity.y),rebound*0.78))
			angular_speed=inward*clampf(rebound/150,0.4,2.0)
	if velocity.y<0:
		return
	var seat := size.y*SEAT_RATIO
	if now<cloud_collision_until and absf(position.x+size.x*0.5-cloud_x)<size.x*0.22 \
		and old.y+seat<=cloud_edge and position.y+seat>=cloud_edge:
		position.y=cloud_edge-seat
		impact_speed=velocity.length()
		falling=false
		velocity=Vector2.ZERO
		landing_at=now
		impact="cloud"
		impact_at=now
		cloud_since=now-0.95
		cloud_seated=true
		cloud_was_seat=true
		cloud_collision_until=0
		return
	var edge := floor
	var landed := Rect2i()
	for window in windows:
		if not _fits(window,desk,size):
			continue
		var y := float(window.position.y)
		if y-foot<top or old.y+foot>y+1 or position.y+foot<y or y>=edge:
			continue
		var crossed := clampf((y-old.y-foot)/maxf(position.y-old.y,0.001),0,1)
		var x := lerpf(old.x,position.x,crossed)+size.x*0.5
		if x>window.position.x+27 and x<window.end.x-27:
			landed=window
			edge=y
	if position.y+foot>=edge:
		position.y=maxf(top,edge-foot)
		falling=false
		var bottom_corner := not landed.has_area() and now-impact_at<=0.12 and impact in ["left","right"]
		impact="bottom_"+impact if bottom_corner else "window" if landed.has_area() else "floor"
		impact_speed=velocity.length()
		impact_at=now
		velocity=Vector2.ZERO
		landing_at=now
		supported=landed.has_area()
		support=landed
		support_id=_id(landed,identities)
		support_origin=_origin(landed,identities)
		support_at=now

func _climb(dt: float, now: float, edge: Rect2i, identities: Dictionary, seat: float, size: Vector2i) -> String:
	climb_progress+=dt/CLIMB_SECONDS
	var lift := smoothstep(0.38,0.91,climb_progress)
	position.y=lerpf(climb_origin.y,float(edge.position.y)-seat,lift)
	if climb_progress<0.18:
		return "approach"
	if climb_progress<0.35:
		return "reach"
	if climb_progress<0.47:
		return "grip"
	if climb_progress<0.85:
		return "pull_up"
	if climb_progress<1:
		return "settle"
	climb_progress=0
	seated=true
	supported=true
	support=edge
	support_id=_id(edge,identities)
	support_origin=_origin(edge,identities)
	support_at=now
	return "sit"

func _id(edge: Rect2i, identities: Dictionary) -> int:
	return int(identities.get(edge,[0,0,0])[0])

func _origin(edge: Rect2i, identities: Dictionary) -> Vector2i:
	var entry: Array=identities.get(edge,[0,edge.position.x,edge.position.y])
	return Vector2i(int(entry[1]),int(entry[2]))

func _nearest_segment(previous: Rect2i, id: int, windows: Array[Rect2i], identities: Dictionary) -> Rect2i:
	var x := position.x
	var found := Rect2i()
	var score := INF
	for edge in windows:
		if id!=0 and _id(edge,identities)!=id:
			continue
		if id==0 and (edge==previous or edge.intersection(previous).get_area()>previous.get_area()*0.72):
			return edge
		if id==0:
			continue
		var distance := absf(edge.position.x-previous.position.x)+absf(edge.end.x-previous.end.x)+absf(edge.position.x-x)*0.01
		if distance<score:
			score=distance
			found=edge
	return found

func _follow(windows: Array[Rect2i], identities: Dictionary) -> Rect2i:
	return _nearest_segment(support,support_id,windows,identities)

func _climb_target(windows: Array[Rect2i], identities: Dictionary) -> Rect2i:
	return _nearest_segment(climb_edge,climb_id,windows,identities)

func _fits(edge: Rect2i, desk: Rect2i, size: Vector2i) -> bool:
	return desk.intersection(edge).size.x>=94 and edge.size.y>0 \
		and edge.position.y>=desk.position.y+size.y*.35+5 \
		and edge.position.y<=desk.end.y-size.y*.31

func _ferry_goal(edge: Rect2i, desk: Rect2i, size: Vector2i) -> Vector2:
	if not _fits(edge,desk,size):
		return Vector2.INF
	var y := edge.position.y-size.y*SEAT_RATIO
	var pad := size.x*.24
	var left := maxf(edge.position.x+pad,desk.position.x+size.x*.5+5)
	var right := minf(edge.end.x-pad,desk.end.x-size.x*.5-5)
	if left>right:
		return Vector2.INF
	return Vector2((left+right-size.x)*.5,y)

func _reachable(windows: Array[Rect2i], foreground: Rect2i, desk: Rect2i, size: Vector2i, foot: float, seat: float, magnet: float) -> Rect2i:
	var best := Rect2i()
	if magnet<=0:
		return best
	var best_score := INF
	var center := position.x+size.x*0.5
	for edge in windows:
		if not _fits(edge,desk,size):
			continue
		var lift := position.y+seat-edge.position.y
		var below := edge.position.y-(position.y+foot)
		var horizontal := absf(center-clampf(center,edge.position.x+40,edge.end.x-40))
		if lift>size.y*(.31+.13*(magnet-1.0)) or below>28.0*magnet or horizontal>size.x*.74*magnet:
			continue
		# A person can reach down from their current ledge only within a short step.
		if support.has_area() and absf(edge.position.y-support.position.y)>size.y*0.30:
			continue
		var score := horizontal+absf(lift)*0.6-(120 if edge==foreground else 0)
		if score<best_score:
			best_score=score
			best=edge
	return best

func _drop_perch(windows: Array[Rect2i], desk: Rect2i, size: Vector2i, seat: float, magnet: float) -> Rect2i:
	var best := Rect2i()
	var nearest := size.y*.18*magnet
	var center := position.x+size.x*.5
	for edge in windows:
		if not _fits(edge,desk,size) or center<edge.position.x+24 or center>edge.end.x-24:
			continue
		var distance := absf(position.y+seat-edge.position.y)
		if distance<nearest:
			nearest=distance
			best=edge
	return best
