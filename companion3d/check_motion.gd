extends SceneTree

const Motion = preload("res://desktop_motion.gd")
const DESK := Rect2i(-1440,0,1440,900)
const SIZE := Vector2i(320,480)
const DT := 1.0/60
var options := {"mode":"windows","physics":true,"gravity":900,"walk_speed":58,"magic":false}
var edges: Array[Rect2i] = []
var body = Motion.new()
var clock := 0.0
var poses := {}
var impacts := {}
var failed := false
var pose := ""

func _step(seconds: float, selected := Rect2i(), identity := {}) -> void:
	for frame in roundi(seconds/DT):
		clock+=DT
		pose=body.update(DT,clock,DESK,SIZE,Vector2i.ZERO,options,edges,selected,identity)
		poses[pose]=true
		impacts[body.impact]=true

func _expect(ok: bool, message: String) -> void:
	if not ok:
		failed=true
		push_error(message)

func _initialize() -> void:
	var close := Rect2i(-1180,640,520,210)
	var above := Rect2i(-1120,340,550,350)
	body.place(Vector2(-990,440))
	edges.assign([above,close])
	_step(1.6,above,{close:[9,-1180,640],above:[7,-1120,340]})
	for state in ["approach","reach","grip","pull_up","settle","sit"]:
		_expect(poses.has(state),"Missing climb phase: "+state)
	_expect(body.seated and body.support==close,"A high foreground edge must not beat a reachable background edge.")
	var first_x: float=body.position.x
	var next := Rect2i(-1160,653,520,204)
	edges.assign([next])
	_step(0.04,next,{next:[9,-1160,653]})
	_expect(body.seated and absf(body.position.x-first_x-20)<1 and body.support==next,"A small window move should carry the seated avatar intact.")
	var fast := Rect2i(-1000,655,520,180)
	edges.assign([fast])
	_step(0.18,fast,{fast:[9,-1000,655]})
	_expect(body.falling and not body.seated,"A large move should break the seat.")
	edges.clear()
	_step(2)
	_expect(not body.falling and body.impact=="floor","A fall should settle on the work-area floor.")

	body.place(Vector2(-990,428))
	edges.assign([close])
	_step(2,close,{close:[9,-1180,640]})
	edges.clear()
	_step(0.15)
	_expect(body.falling,"An obscured or closed window should release the avatar.")
	_step(2)
	options.magic=true
	poses.clear()
	_step(2)
	_expect(poses.has("look_around") and poses.has("cloud_summon") and pose=="cloud_sit" and body.cloud_alpha>0.9,"The cloud needs a summon and a seated support.")
	body.grab(clock,body.position.y+SIZE.y*Motion.SEAT_RATIO)
	body.drag_to(body.position-Vector2(0,70),Vector2(0,-100),0.05)
	body.release(Vector2(0,-30),true,clock)
	_step(0.6)
	_expect(body.impact=="cloud","A nearby throw should land on the surviving cloud.")
	var cloud_exit := Rect2i(-1170,663,540,190)
	edges.assign([cloud_exit])
	_step(3,cloud_exit,{cloud_exit:[12,-1170,663]})
	_expect(body.seated and body.cloud_alpha<0.1,"A reachable window should replace the cloud.")
	options.magic=false
	options.mode="taskbar"
	edges.clear()
	_step(2)
	_expect(pose=="idle" and body.cloud_alpha==0,"Taskbar mode should remain standing.")

	body.grab()
	body.release(Vector2(42,-290),true,clock)
	_step(1.4)
	_expect(not body.falling and body.impact=="floor","Taskbar throws must complete without window edges.")
	options.mode="windows"
	for sample in [[Vector2(-1430,90),Vector2(-1000,0),"left"],[Vector2(-330,90),Vector2(1000,0),"right"],
		[Vector2(-900,13),Vector2(0,-900),"top"],[Vector2(-1430,10),Vector2(-705,-705),"top_left"],
		[Vector2(-330,10),Vector2(705,-705),"top_right"],
		[Vector2(-1400,70),Vector2(-750,-750),"top_left"],
		[Vector2(-390,32),Vector2(750,-750),"top_right"],
		[Vector2(-1420,405),Vector2(-650,750),"bottom_left"],
		[Vector2(-345,405),Vector2(650,750),"bottom_right"]]:
		body.place(sample[0])
		body.grab()
		body.release(sample[1],true,clock)
		impacts.clear()
		_step(1.9)
		_expect(impacts.has(sample[2]),"Missing boundary impact: "+sample[2])
		_expect(body.position.x>=DESK.position.x and body.position.x+SIZE.x<=DESK.end.x and not body.falling,"Throw did not settle within the monitor.")
	body.place(Vector2(-990,40))
	body.grab()
	body.release(Vector2(55,0),true,clock)
	edges.assign([close])
	_step(0.85,close)
	_expect(body.impact=="window" and body.support==close,"Swept landing should catch an exposed edge.")
	body.grab()
	var initial: Vector2=body.position
	var destination := initial+Vector2(80,0)
	body.drag_to(destination,Vector2(200,0),DT)
	_expect(body.position.x>initial.x and body.position.x<destination.x,"Drag should follow a damped spring.")
	# Interrupt a climb, then a cloud pose, without waiting for the prior state.
	var interrupt = Motion.new()
	interrupt.place(Vector2(-990,440))
	var climb_edges: Array[Rect2i]=[close]
	for frame in 25:
		interrupt.update(DT,frame*DT,DESK,SIZE,Vector2i.ZERO,options,climb_edges)
	_expect(interrupt.climb_progress>0,"The fixture did not enter a climb.")
	interrupt.grab()
	_expect(interrupt.held and interrupt.climb_progress==0,"Grabbing must cancel a climb immediately.")
	interrupt.place(Vector2(-990,440))
	_expect(not interrupt.held,"Restoring a position must cancel the previous drag.")
	var magic_options:=options.duplicate()
	magic_options.magic=true
	climb_edges.clear()
	for frame in 130:
		interrupt.update(DT,frame*DT,DESK,SIZE,Vector2i.ZERO,magic_options,climb_edges)
	_expect(interrupt.cloud_seated,"The fixture did not sit on a cloud.")
	magic_options.magic=false
	interrupt.update(DT,2.2,DESK,SIZE,Vector2i.ZERO,magic_options,climb_edges)
	_expect(not interrupt.cloud_seated and interrupt.cloud_collision_until==0,"Magic off must clear cloud support immediately.")
	options.mode="roam"
	options.magic=true
	edges.clear()
	body=Motion.new()
	body.place(Vector2(-900,410))
	clock=0.0
	poses.clear()
	_step(1.8)
	_expect(body.cloud_seated,"Free Roam should be able to rest on a cloud.")
	body.interrupt(clock, true)
	_step(1.0)
	_expect(body.cloud_seated,"A tap must preserve the current safe perch.")
	_step(15.0)
	_expect(poses.has("walk") and not body.cloud_seated,"Free Roam must leave the cloud for a short walk.")
	var pending=Motion.new()
	pending.climb_progress=0.7
	pending.interrupt(clock,true)
	_expect(pending.climb_progress==0 and pending.falling,"Takeover must cancel an active climb safely.")
	if not failed:
		print("Companion motion: reachable ledges, all climb phases, moving/removed supports, fast release, clouds, bounded throws and spring drag passed.")
	quit(1 if failed else 0)
