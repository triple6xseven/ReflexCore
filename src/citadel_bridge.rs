//! Citadel intelligence bridge 0.6.0: bounded, line-delimited JSON over a single
//! long-lived Rust child. This module NEVER sends Windows input or executes shell.
//! Citadel owns state and performs actions; Rust proposes and verifies readbacks.
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{collections::{HashMap, HashSet}, env, fs::{self, OpenOptions}, io::{self, BufRead, Write}, path::PathBuf};

type R<T> = Result<T, String>;
const SCHEMA: &str = "reflexcore.citadel.bridge.v1";
const EXPERIENCE: &str = "reflexcore.citadel.experience.v1";
const MAX_LINE: usize = 16384;
const MAX_SEQ: u64 = 2500;
const TYPES: [&str;5] = ["giant", "archer", "sapper", "raider", "medic"];

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all="camelCase", deny_unknown_fields)]
pub(crate) struct Unit {pub id: u64, pub r#type: String, pub x:f64, pub y:f64, pub hp:f64, pub max:f64}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all="camelCase", deny_unknown_fields)]
pub(crate) struct Building {pub id:String, pub r#type:String, pub x:f64, pub y:f64, pub hp:f64, pub max:f64}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Stats {pub deployed:u32, pub lost:u32, pub damage:f64}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Plan {pub remaining:HashMap<String,u32>}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all="camelCase", deny_unknown_fields)]
pub(crate) struct World {
 pub phase:String,pub mission:String,pub elapsed:f64,pub budget:u32,pub spent:u32,pub remaining:u32,
 pub core_hp:f64,pub buildings:Vec<Building>,pub units:Vec<Unit>,pub stats:Stats,
 pub plan:Option<Plan>,pub cooldowns:HashMap<String,f64>,pub sonar:bool,pub overdrive:bool,
 pub focus_target_id:Option<String>,
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {schema:String,seq:u64,op:String,world:Option<World>}
#[derive(Clone, Debug, Serialize)]
pub(crate) struct Action {
 pub kind:&'static str,
 #[serde(skip_serializing_if="Option::is_none")] pub r#type:Option<String>,
 #[serde(skip_serializing_if="Option::is_none")] pub name:Option<String>,
 #[serde(skip_serializing_if="Option::is_none")] pub id:Option<String>,
 #[serde(skip_serializing_if="Option::is_none")] pub x:Option<i32>,
 #[serde(skip_serializing_if="Option::is_none")] pub y:Option<i32>,
 #[serde(skip_serializing_if="Option::is_none")] pub lane:Option<String>,
 pub reason:&'static str,
}
impl Action {
 fn deploy(ty:&str,x:i32,y:i32)->Self {Self{kind:"deploy",r#type:Some(ty.into()),name:None,id:None,x:Some(x),y:Some(y),lane:Some((if y<240 {"north"} else if y>400 {"south"} else {"center"}).to_string()),reason:"Rust goal planner: live threats, cost and verified experience"}}
 fn skill(name:&str)->Self {Self{kind:"skill",r#type:None,name:Some(name.into()),id:None,x:None,y:None,lane:None,reason:"Rust reflex: observed battle conditions and cooldown"}}
 fn focus(b:&Building)->Self {Self{kind:"focus",r#type:None,name:None,id:Some(b.id.clone()),x:Some(b.x.round() as i32),y:Some(b.y.round() as i32),lane:None,reason:"Rust goal planner: prioritize live defense"}}
}
struct Pending {before:World, action:Action}
#[derive(Default)]
struct Bridge {seq:u64, started:bool, finished:bool, mission:String, pending:Option<Pending>,
 deployment_index:u32, last_focus:f64, failed:HashMap<String,u32>, verified:u32,
 last_elapsed:f64, last_deployed:u32,}

fn fail(code:&str)->Value {json!({"schema":SCHEMA,"ok":false,"error":code})}
fn finite_range(v:f64,low:f64,high:f64)->bool {v.is_finite()&&v>=low&&v<=high}
fn valid_world(w:&World)->R<()> {
 if !matches!(w.mission.as_str(),"destroy-core"|"disable-defenses"|"no-giants")
  || !matches!(w.phase.as_str(),"planning"|"deploy"|"battle"|"done"|"paused")
  || w.budget>5000||w.spent>w.budget||w.remaining!=w.budget-w.spent
  || !finite_range(w.elapsed,0.,3600.)||!finite_range(w.core_hp,0.,10000.)
  || !finite_range(w.stats.damage,0.,1_000_000.)||w.stats.deployed>100||w.stats.lost>100
  || w.units.len()>100||w.buildings.len()>40||w.cooldowns.len()>8 {return Err("INVALID_WORLD".into());}
 let mut ids=HashSet::new();
 for u in &w.units {if u.id==0||!ids.insert(u.id)||!TYPES.contains(&u.r#type.as_str())
   ||!finite_range(u.x,0.,1024.)||!finite_range(u.y,0.,640.)||!finite_range(u.max,1.,10000.)||!finite_range(u.hp,0.,u.max) {return Err("INVALID_UNIT".into());}}
 if w.buildings.iter().filter(|b| b.r#type=="core").count()!=1 {return Err("MISSING_OR_DUPLICATE_CORE".into());}
 let mut buildings=HashSet::new();
 for b in &w.buildings {if b.id.is_empty()||b.id.len()>40||!b.id.bytes().all(|c|c.is_ascii_alphanumeric()||c==b'-')
   ||!buildings.insert(b.id.as_str())||!matches!(b.r#type.as_str(),"core"|"cannon"|"tower"|"wall")
   ||!finite_range(b.x,0.,1024.)||!finite_range(b.y,0.,640.)||!finite_range(b.max,1.,10000.)||!finite_range(b.hp,0.,b.max){return Err("INVALID_BUILDING".into());}}
 for (k,v) in &w.cooldowns {if !matches!(k.as_str(),"sonar"|"heal"|"rage")||!finite_range(*v,0.,4000.) {return Err("INVALID_COOLDOWN".into());}}
 if let Some(p)=&w.plan {if p.remaining.len()>5||p.remaining.iter().any(|(k,v)|!TYPES.contains(&k.as_str())||*v>30){return Err("INVALID_PLAN".into());}}
 if w.phase=="deploy"&&w.plan.is_none() {return Err("MISSING_PLAN".into());}
 Ok(())
}
fn cost(t:&str)->u32 {match t {"giant"=>55,"archer"=>25,"sapper"=>40,"raider"=>30,"medic"=>35,_=>u32::MAX}}
fn living<'a>(w:&'a World,kind:&str)->impl Iterator<Item=&'a Building> {let k=kind.to_string();w.buildings.iter().filter(move |b|b.hp>0.&&b.r#type==k)}
fn deploy(w:&World,index:u32,failures:&HashMap<String,u32>)->Option<Action> {
 if !matches!(w.phase.as_str(),"deploy"|"battle") {return None;}
 let remaining=&w.plan.as_ref()?.remaining;
 let walls=living(w,"wall").count();
 let threats=w.buildings.iter().filter(|b|b.hp>0.&&matches!(b.r#type.as_str(),"cannon"|"tower"|"core")).count();
 let injured=w.units.iter().any(|u|u.hp/u.max<0.62);
 let signals=crate::agent::CitadelSignals{walls,threats,allies:w.units.len(),injured,
  no_giants:w.mission=="no-giants",disable_defenses:w.mission=="disable-defenses"};
 let ty=TYPES.iter().filter(|&&t|remaining.get(t).copied().unwrap_or(0)>0&&cost(t)<=w.remaining)
  .max_by_key(|&&t| (crate::agent::citadel_skill_score(t,&signals,failures.get(t).copied().unwrap_or(0)),
   -(TYPES.iter().position(|&x|x==t).unwrap_or(0) as i32)))?;
 if w.mission=="no-giants"&&*ty=="giant" {return None;}
 let target=if *ty=="sapper" {living(w,"wall").next()}
  else if *ty=="giant" {living(w,"cannon").next()}
  else if *ty=="medic" {None}
  else {living(w,"tower").next()};
 let base=target.or_else(||w.buildings.iter().find(|b|b.hp>0.&&matches!(b.r#type.as_str(),"cannon"|"tower"|"core")))
  .map(|b|b.y).unwrap_or(320.);
 let y0=if base<240. {170} else if base>400. {470} else {320};
 let x=(100+((index*71)%170) as i32).clamp(50,315);
 let y=(y0+((index*37)%91) as i32-45).clamp(50,590);
 Some(Action::deploy(ty,x,y))
}
fn combat(w:&World,last_focus:f64)->Option<Action> {
 if w.phase!="battle"||w.units.is_empty(){return None;}
 let ready=|key:&str|w.elapsed+0.0001>=w.cooldowns.get(key).copied().unwrap_or(0.);
 let threats:Vec<_>=w.buildings.iter().filter(|b|b.hp>0.&&matches!(b.r#type.as_str(),"core"|"cannon"|"tower")).collect();
 if !w.sonar&&ready("sonar")&&w.elapsed>1.5&&!threats.is_empty()&&w.units.len()>=2 {return Some(Action::skill("sonar"));}
 if ready("heal")&&w.units.iter().any(|u|u.hp/u.max<0.55) {return Some(Action::skill("heal"));}
 if !w.overdrive&&ready("rage")&&(w.core_hp<350.||w.elapsed>=10.) {return Some(Action::skill("rage"));}
 let target=threats.iter().find(|b|b.r#type=="cannon").or_else(||threats.iter().find(|b|b.r#type=="tower")).or_else(||threats.first()).copied();
 if let Some(t)=target {if w.focus_target_id.as_deref()!=Some(t.id.as_str())&&w.elapsed-last_focus>=4. {return Some(Action::focus(t));}}
 None
}
fn verify(before:&World,after:&World,a:&Action)->R<&'static str> {
 if before.mission!=after.mission||after.elapsed+0.2<before.elapsed {return Err("TIME_OR_MISSION_REWIND".into());}
 match a.kind {
  "deploy"=>{
   let ty=a.r#type.as_deref().ok_or("ACTION_INVALID")?;
   let x=a.x.ok_or("ACTION_INVALID")? as f64;let y=a.y.ok_or("ACTION_INVALID")? as f64;
   let before_ids:HashSet<_>=before.units.iter().map(|u|u.id).collect();
   let spawned:Vec<_>=after.units.iter().filter(|u|!before_ids.contains(&u.id)).collect();
   if spawned.len()!=1||spawned[0].r#type!=ty||(spawned[0].x-x).hypot(spawned[0].y-y)>=3.
     ||after.spent.checked_sub(before.spent)!=Some(cost(ty))
     ||after.stats.deployed!=before.stats.deployed+1
     ||before.plan.as_ref().and_then(|p|p.remaining.get(ty)).and_then(|n|n.checked_sub(1))
       !=after.plan.as_ref().and_then(|p|p.remaining.get(ty)).copied() {return Err("DEPLOYMENT_NOT_VERIFIED".into());}
   Ok("UNIT_CREATED_VERIFIED")
  },
  "skill"=>{
   let name=a.name.as_deref().ok_or("ACTION_INVALID")?;
   if before.phase!="battle"||after.cooldowns.get(name).copied().unwrap_or(0.)<=before.cooldowns.get(name).copied().unwrap_or(0.)
   {return Err("SKILL_NOT_VERIFIED".into());}
   Ok("COOLDOWN_VERIFIED")
  },
  "focus"=>{
   if before.phase!="battle"||after.focus_target_id!=a.id {return Err("FOCUS_NOT_VERIFIED".into());}
   Ok("FOCUS_TARGET_VERIFIED")
  },
  _=>Err("ACTION_INVALID".into()),
 }
}
fn goal(w:&World)->bool {
 if w.phase!="done" {return false;}
 if w.mission=="disable-defenses" {w.buildings.iter().any(|b|matches!(b.r#type.as_str(),"cannon"|"tower")) && w.buildings.iter().filter(|b|matches!(b.r#type.as_str(),"cannon"|"tower")).all(|b|b.hp==0.)}
 else {w.core_hp==0.}
}
fn memory_path()->Option<PathBuf>{
 let base=env::var_os("LOCALAPPDATA")?;
 Some(PathBuf::from(base).join("ReflexCore").join("private").join("citadel").join("experience.jsonl"))
}
fn load_failure_counts()->HashMap<String,u32> {
 let mut counts=HashMap::new();
 let Some(path)=memory_path() else{return counts};
 if path.metadata().map(|m|m.len()>512*1024).unwrap_or(true){return counts;}
 if let Ok(contents)=fs::read_to_string(path){for line in contents.lines().rev().take(200){
  if let Ok(v)=serde_json::from_str::<Value>(line){
   if v.get("schema").and_then(Value::as_str)!=Some(EXPERIENCE) {continue;}
   if v.get("kind").and_then(Value::as_str)==Some("deploy")&&v.get("verified").and_then(Value::as_bool)==Some(false){
    if let Some(t)=v.get("type").and_then(Value::as_str){if TYPES.contains(&t){*counts.entry(t.into()).or_insert(0)+=1;}}
   }
  }
 }}
 counts
}
fn record(mission:&str,a:&Action,verified:bool,delta_damage:f64){
 let Some(path)=memory_path() else{return};
 if let Some(dir)=path.parent(){if fs::create_dir_all(dir).is_err(){return;}}
 if path.metadata().map(|m|m.len()>512*1024).unwrap_or(false){return;}
 let line=json!({"schema":EXPERIENCE,"mission":mission,"kind":a.kind,"type":a.r#type.as_deref().or(a.name.as_deref()).unwrap_or("focus"),
   "verified":verified,"damage_delta":delta_damage.max(0.).min(10000.).round()});
 if let Ok(mut f)=OpenOptions::new().create(true).append(true).open(path){let _=writeln!(f,"{line}");}
}
impl Bridge {
 fn step(&mut self,req:Request)->R<Value>{
  if req.schema!=SCHEMA||req.seq==0||req.seq>MAX_SEQ||req.seq!=self.seq+1 {return Err("SCHEMA_OR_SEQUENCE_REJECTED".into());}
  let w=req.world.ok_or("WORLD_REQUIRED")?;valid_world(&w)?;
  if req.op=="start" {
   if self.started||req.seq!=1||w.phase!="deploy" {return Err("START_REJECTED".into());}
   self.started=true;self.mission=w.mission.clone();self.last_focus=-100.;self.failed=load_failure_counts();
   self.last_elapsed=w.elapsed;self.last_deployed=w.stats.deployed;self.seq=req.seq;
   return Ok(json!({"schema":SCHEMA,"ok":true,"code":"RUST_GOAL_AGENT_READY","planner":"rust_goal_agent_v1"}));
  }
  if !self.started||self.finished||w.mission!=self.mission{return Err("SESSION_NOT_ACTIVE".into());}
  match req.op.as_str(){
   "next"=>{
    if self.pending.is_some()||w.phase=="paused"||w.elapsed+0.2<self.last_elapsed||w.stats.deployed<self.last_deployed {return Err("STATE_REWIND_OR_PENDING".into());}
    let action=if self.deployment_index<24 {deploy(&w,self.deployment_index,&self.failed)}else{None};
    let action=action.or_else(||combat(&w,self.last_focus));
    self.seq=req.seq;self.last_elapsed=w.elapsed;self.last_deployed=w.stats.deployed;
    if let Some(a)=action {self.pending=Some(Pending{before:w,action:a.clone()});Ok(json!({"schema":SCHEMA,"ok":true,"action":a,"code":"ACTION_PROPOSED"}))}
    else {Ok(json!({"schema":SCHEMA,"ok":true,"action":null,"code":"NO_VALID_ACTION"}))}
   },
   "commit"=>{
    let p=self.pending.take().ok_or("UNSOLICITED_COMMIT")?;
    let proof=verify(&p.before,&w,&p.action);
    self.seq=req.seq;self.last_elapsed=w.elapsed;self.last_deployed=w.stats.deployed;
    if p.action.kind=="deploy"{self.deployment_index+=1;}
    if p.action.kind=="focus"{self.last_focus=w.elapsed;}
    record(&self.mission,&p.action,proof.is_ok(),w.stats.damage-p.before.stats.damage);
    let code=match proof {Ok(code)=>code,Err(code)=>{self.finished=true;return Err(code);}};
    self.verified+=1;
    Ok(json!({"schema":SCHEMA,"ok":true,"code":code,"verified":true,"verified_steps":self.verified}))
   },
   "finish"=>{
    if self.pending.is_some()||w.phase!="done" {return Err("FINISH_REJECTED".into());}
    self.seq=req.seq;self.finished=true;
    Ok(json!({"schema":SCHEMA,"ok":true,"code":if goal(&w){"GOAL_VERIFIED"}else{"GOAL_FAILED"},"goal_verified":goal(&w),"verified_steps":self.verified}))
   },
   _=>Err("UNKNOWN_OPERATION".into()),
  }
 }
}
pub(crate) fn run(args:&[String])->Result<(),Box<dyn std::error::Error>>{
 if args.len()!=1||args[0]!="serve" {return Err("Usage: reflexcore citadel-bridge serve".into());}
 let stdin=io::stdin();let mut bridge=Bridge::default();let mut stdout=io::BufWriter::new(io::stdout().lock());
 for line in stdin.lock().lines(){
  let line=line?;let response=if line.len()>MAX_LINE {fail("REQUEST_TOO_LARGE")} else {
   match serde_json::from_str::<Request>(&line){Ok(req)=>match bridge.step(req){Ok(v)=>v,Err(code)=>fail(&code)},Err(_)=>fail("INVALID_REQUEST")}
  };
  writeln!(stdout,"{response}")?;stdout.flush()?;
 }
 Ok(())
}
#[cfg(test)]
mod tests {
 use super::*;
 fn world()->World {serde_json::from_value(json!({"phase":"deploy","mission":"destroy-core","elapsed":0,"budget":260,"spent":0,"remaining":260,"coreHp":480,
   "buildings":[{"id":"core","type":"core","x":880,"y":356,"hp":480,"max":480},{"id":"wall-n","type":"wall","x":640,"y":170,"hp":220,"max":220}],
   "units":[],"stats":{"deployed":0,"lost":0,"damage":0},"plan":{"remaining":{"giant":2,"archer":4,"sapper":1,"raider":0,"medic":0}},
   "cooldowns":{"sonar":0,"heal":0,"rage":0},"sonar":false,"overdrive":false,"focusTargetId":null})).unwrap()}
 fn request(op:&str,seq:u64,w:World)->Request{Request{schema:SCHEMA.into(),op:op.into(),seq,world:Some(w)}}
 fn clone_world(w:&World)->World{serde_json::from_value(serde_json::to_value(w).unwrap()).unwrap()}
 #[test]fn bounded_deployment_and_readback(){let w=world();let mut b=Bridge::default();assert!(b.step(request("start",1,clone_world(&w))).is_ok());
  let a=b.step(request("next",2,clone_world(&w))).unwrap();let action=a.get("action").unwrap();let ty=action.get("type").unwrap().as_str().unwrap();
  let mut after=clone_world(&w);after.spent=cost(ty);after.remaining=260-after.spent;after.stats.deployed=1;
  *after.plan.as_mut().unwrap().remaining.get_mut(ty).unwrap()-=1;
  after.units.push(Unit{id:1,r#type:ty.into(),x:action["x"].as_i64().unwrap() as f64,y:action["y"].as_i64().unwrap() as f64,hp:100.,max:100.});
  assert_eq!(b.step(request("commit",3,after)).unwrap()["verified"],true);
  assert!(b.step(request("next",3,clone_world(&w))).is_err());
 }
 #[test]fn refuses_unverified_effect(){let w=world();let mut b=Bridge::default();b.step(request("start",1,clone_world(&w))).unwrap();b.step(request("next",2,clone_world(&w))).unwrap();
  assert!(b.step(request("commit",3,clone_world(&w))).is_err());assert!(b.finished);
 }
 #[test]fn disallow_replay_and_fake_goal(){let w=world();let mut b=Bridge::default();b.step(request("start",1,clone_world(&w))).unwrap();
  assert!(b.step(request("start",2,clone_world(&w))).is_err());assert!(!goal(&w));
  let mut g=clone_world(&w);g.phase="done".into();assert!(!goal(&g));g.core_hp=0.;assert!(goal(&g));
 }
 #[test]fn state_validation(){let mut w=world();w.remaining=200;assert!(valid_world(&w).is_err());w.remaining=260;w.units.push(Unit{id:1,r#type:"giant".into(),x:1100.,y:150.,hp:10.,max:100.});assert!(valid_world(&w).is_err());}
}
