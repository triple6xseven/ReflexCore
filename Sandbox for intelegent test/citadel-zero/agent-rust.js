/* ReflexCore 0.6.0 — Rust Goal Agent client. This never performs game or OS actions.
 * It only sends bounded game-state observations and receives a candidate action.
 */
(function(root){'use strict';
const SCHEMA='reflexcore.citadel.bridge.v1';
let session=null,sequence=0,controller=null;
function world(s){
 if(!s)throw Error('Missing Citadel game snapshot');
 return {
  phase:s.phase,mission:s.mission,elapsed:s.elapsed,
  budget:s.budget,spent:s.spent,remaining:s.remaining,coreHp:s.coreHp,
  plan:s.plan?{remaining:{...s.plan.remaining}}:null,
  buildings:s.buildings.map(b=>({id:b.id,type:b.type,x:b.x,y:b.y,hp:b.hp,max:b.max})),
  units:s.units.map(u=>({id:u.id,type:u.type,x:u.x,y:u.y,hp:u.hp,max:u.max})),
  stats:{deployed:s.stats.deployed,lost:s.stats.lost,damage:s.stats.damage},
  cooldowns:{sonar:s.cooldowns.sonar,heal:s.cooldowns.heal,rage:s.cooldowns.rage},
  sonar:!!s.sonar,overdrive:!!s.overdrive,focusTargetId:s.focusTargetId??null
 };
}
async function call(op,snapshot){
 if(!['start','next','commit','finish'].includes(op))throw Error('Forbidden Rust bridge operation');
 if(op==='start'){
  if(session)throw Error('Rust bridge session already active');
  sequence=0;controller=new AbortController();
 }else if(!session)throw Error('Rust bridge not started');
 const payload={schema:SCHEMA,seq:++sequence,world:world(snapshot)};
 if(session)payload.token=session;
 let response;
 try {response=await fetch('/api/agent/rust/'+op,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload),signal:controller?.signal});}
 catch(e){throw Error('Rust bridge HTTP unavailable or cancelled: '+String(e.message||e));}
 const data=await response.json();
 if(!response.ok||!data.ok||data.schema!==SCHEMA)throw Error('Rust bridge rejected operation: '+String(data.error||response.status));
 if(op==='start'){
  if(typeof data.token!=='string'||!(/^[0-9a-f]{32}$/).test(data.token))throw Error('Rust bridge session token invalid');
  session=data.token;
 }
 if(op==='next'&&data.action!==null){
  const a=data.action;
  if(!a||!['deploy','focus','skill'].includes(a.kind))throw Error('Rust returned forbidden action');
  if(a.kind==='deploy'&&(!['giant','archer','sapper','raider','medic'].includes(a.type)||!Number.isInteger(a.x)||!Number.isInteger(a.y)||a.x<35||a.x>370||a.y<25||a.y>615))throw Error('Rust returned invalid deployment');
  if(a.kind==='skill'&&!['sonar','heal','rage'].includes(a.name))throw Error('Rust returned forbidden skill');
  if(a.kind==='focus'&&(!Number.isInteger(a.x)||!Number.isInteger(a.y)||typeof a.id!=='string'))throw Error('Rust returned invalid target');
 }
 return data;
}
async function stop(){
 controller?.abort();controller=null;session=null;sequence=0;
 try{await fetch('/api/agent/rust/stop',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});}catch{}
}
const client=Object.freeze({world,start:s=>call('start',s),next:s=>call('next',s),commit:s=>call('commit',s),finish:s=>call('finish',s),stop,get active(){return !!session;}});
if(typeof module!=='undefined'&&module.exports)module.exports=client;
root.ReflexCitadelRust=client;
})(typeof window!=='undefined'?window:globalThis);
