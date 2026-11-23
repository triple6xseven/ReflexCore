/* ReflexCore 0.4.5 — evidence-driven Visible Agent; native cursor is still explicit opt-in. */
(()=>{'use strict';
const game=window.ReflexCitadel,policy=window.ReflexCitadelPolicy,rust=window.ReflexCitadelRust;
if(!game||!policy){console.error('Citadel game or tactics API unavailable');return;}
const $=id=>document.getElementById(id);
const logArea=$('agent-log'),cursor=$('agent-cursor'),startButton=$('agent-start'),stopButton=$('agent-stop');
let runId=0,running=false,headlessController=null;
let trace=null,lastTrace=null,verifiedCount=0;
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
function log(text){
  const line='['+new Date().toLocaleTimeString('ru-RU')+'] '+String(text).slice(0,180);
  logArea.textContent=(logArea.textContent==='The agent is waiting for a command.'?'':logArea.textContent+'\n')+line;
  const rows=logArea.textContent.split('\n');if(rows.length>24)logArea.textContent=rows.slice(-24).join('\n');
  logArea.scrollTop=logArea.scrollHeight;
}
function state(value){running=value;startButton.disabled=value;stopButton.disabled=!value;$('agent-replay').disabled=value||!lastTrace?.steps?.some(x=>x.action==='deploy'&&x.verified);}
// Reports contain game-only observations. No screenshots, window titles, prompts or API credentials.
function observer(stage,evidence='',level='normal'){
 const panel=document.querySelector('.agent-observer');
 if(panel){panel.classList.toggle('is-error',level==='error');panel.classList.toggle('is-success',level==='success');}
 $('agent-stage').textContent=stage;
 $('agent-evidence').textContent=evidence||'Waiting for a game result';
 $('agent-trace-count').textContent=verifiedCount+' / '+(trace?.steps?.filter(x=>x.action==='deploy'||x.action==='skill'||x.action==='focus').length||0)+' VERIFIED';
}
function startTrace(kind){
 verifiedCount=0;trace={schema:'reflexcore.citadel.agent-trace.v1',version:'0.4.5',mode:kind,mission:game.snapshot().mission,
  status:'running',result:'unknown',steps:[],total_ms:0};trace.started=performance.now();
 observer('OBSERVATION · '+kind,'No actions sent');
}
function evidence(action,reason,before,after,proof,ms){
 if(!trace)return;
 const record={seq:trace.steps.length+1,action:action.kind,type:action.type||action.name||action.id||'',
  x:Number.isFinite(action.x)?Math.round(action.x):null,y:Number.isFinite(action.y)?Math.round(action.y):null,
  reason:String(reason||'').slice(0,120),verified:!!proof.ok,code:String(proof.code||'UNKNOWN'),
  unit_id:proof.unitId??null,sim_time_s:Number((after?.elapsed||0).toFixed(2)),
  before:{units:before?.units?.length||0,remaining:before?.remaining??null,core_hp:before?.coreHp??null},
  after:{units:after?.units?.length||0,remaining:after?.remaining??null,core_hp:after?.coreHp??null},
  ms:Math.max(0,Math.round(ms))};
 trace.steps.push(record);if(trace.steps.length>400)trace.steps.shift();
 if(proof.ok&&['deploy','skill','focus'].includes(action.kind))verifiedCount++;
 observer((proof.ok?'VERIFIED':'UNVERIFIED')+' · '+action.kind.toUpperCase()+' '+record.type,
  record.code+' · '+record.ms+'ms · Core HP '+after.coreHp+' · Remaining '+after.remaining,
  proof.ok?'success':'error');
}
function finishTrace(status,result){
 if(!trace)return;trace.status=status;trace.result=result;
 trace.total_ms=Math.max(0,Math.round(performance.now()-trace.started));delete trace.started;
 lastTrace=JSON.parse(JSON.stringify(trace));
 $('agent-replay').disabled=running||!lastTrace.steps.some(x=>x.action==='deploy'&&x.verified);
 if(result==='verified_win')observer('OBJECTIVE VERIFIED','Target HP reached 0. The trace contains the actions and result.','success');
 else if(result==='verified_loss')observer('OBJECTIVE MISSED','The battle ended before meeting the objective.','error');
}
function downloadTrace(){
 if(!trace&&!lastTrace){log('There is no trace to export yet.');return;}
 const safe=trace?.status==='running'?{...trace,total_ms:Math.round(performance.now()-trace.started)}:(lastTrace||trace);
 const copy={...safe};delete copy.started;
 const blob=new Blob([JSON.stringify(copy,null,2)],{type:'application/json'});
 const url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download='citadel-agent-trace-'+Date.now()+'.json';
 document.body.appendChild(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),1500);
}
$('agent-export').addEventListener('click',downloadTrace);
function dropPoint(x,y){
 const r=$('deployment-layer').getBoundingClientRect();
 if(r.width<=0||r.height<=0)throw Error('Deployment layer unavailable');
 return {x:r.left+x*r.width/1024,y:r.top+y*r.height/640};
}
async function performDeployment(action,id,physical){
 const card=document.querySelector('.troop[data-type="'+action.type+'"]');
 if(!card||card.disabled)throw Error('Card disabled or missing: '+action.type);
 const drop=dropPoint(action.x,action.y);
 const before=game.snapshot(),begin=performance.now();
 observer('ACTION · '+action.type.toUpperCase(),action.reason+' → ['+action.x+','+action.y+']');
 if(physical)await physicalDrag(card,drop,id);else await browserDrag(card,drop,id);
 await wait(95);ensureActive(id);
 const after=game.snapshot(),proof=policy.proveDeploy(before,after,action);
 evidence(action,action.reason,before,after,proof,performance.now()-begin);
 if(proof.ok&&$('agent-brain').value==='rust')await confirm3DReadback(after.units.length,id);
 if(!proof.ok)throw Error('Deployment unverified · '+proof.code+'. Retry requires verification.');
 return proof;
}

// The 3D renderer must acknowledge a frame containing the deployed unit count.
// This is renderer telemetry, not a pixel-identification proof; if it stalls,
// switch to the real 2D battle rather than hiding game state behind dead WebGL.
async function confirm3DReadback(unitCount,id){
 if($('scene-mode').value!=='3d')return;
 for(let n=0;n<15;n++){
  ensureActive(id);
  if($('scene-mode').value!=='3d')return;
  if(lastRenderConfirmed>0&&lastRenderedUnitCount>=unitCount)return;
  await wait(100);
 }
 fallbackToVisibleBattle('3D rendering did not confirm an image with the deployed squad.');
}
function spotlight(el){
  if(!el)return;document.querySelectorAll('.agent-target').forEach(x=>x.classList.remove('agent-target'));
  el.classList.add('agent-target');const box=el.getBoundingClientRect();
  cursor.style.left=(box.left+box.width*.5)+'px';cursor.style.top=(box.top+box.height*.5)+'px';cursor.classList.add('active');
}
function clearSpotlight(){cursor.classList.remove('active');document.querySelectorAll('.agent-target').forEach(x=>x.classList.remove('agent-target'));}
function ensureActive(id){if(id!==runId)throw Error('Operation stopped');}
const PHYSICAL_BASE='/api/agent/physical/';
let nativeToken=null,physicalDriving=false;
async function nativeCall(name,payload){
 const r=await fetch(PHYSICAL_BASE+name,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)});
 const result=await r.json();if(!r.ok||!result.ok)throw Error(result.error||'Native mouse bridge unavailable');return result;
}
async function stopNative(){nativeToken=null;try{await nativeCall('stop',{});}catch{}}
function center(el){const r=el.getBoundingClientRect();return {x:r.left+r.width/2,y:r.top+r.height/2};}
function deployCoords(lane,index){
 const r=$('deployment-layer').getBoundingClientRect(),y={north:166,center:318,south:475}[lane]||318;
 return {x:r.left+(95+(index%3)*55)*r.width/1024,y:r.top+(y+(index%3-1)*12)*r.height/640};
}
async function browserDrag(card,drop,id){
 const from=center(card);
 cursor.style.left=from.x+'px';cursor.style.top=from.y+'px';cursor.classList.add('active');await wait(260);ensureActive(id);
 const pointer=(type,x,y)=>new PointerEvent(type,{bubbles:true,cancelable:true,pointerId:173,clientX:x,clientY:y,pointerType:'mouse',button:0,buttons:type==='pointerup'?0:1});
 card.dispatchEvent(pointer('pointerdown',from.x,from.y));
 cursor.style.left=drop.x+'px';cursor.style.top=drop.y+'px';
 await wait(390);ensureActive(id);
 window.dispatchEvent(pointer('pointermove',drop.x,drop.y));
 window.dispatchEvent(pointer('pointerup',drop.x,drop.y));
 await wait(90);
}
async function physicalDrag(card,drop,id){
 if(!nativeToken)throw Error('Native mouse bridge not authorized');
 const from=center(card),r=$('deployment-layer').getBoundingClientRect();
 physicalDriving=true;
 try{await nativeCall('drag',{
   token:nativeToken,start_x:Math.round(from.x),start_y:Math.round(from.y),
   end_x:Math.round(drop.x),end_y:Math.round(drop.y),
   viewport_x:Math.round(r.left),viewport_w:Math.round(r.width),viewport_y:Math.round(r.top),viewport_h:Math.round(r.height)
 });}finally{physicalDriving=false;}
 ensureActive(id);
}
async function visible(id,physical){
 document.body.classList.remove('headless-run');const useRust=$('agent-brain').value==='rust';
 if(useRust&&!rust)throw Error('Rust bridge JavaScript not loaded');
 startTrace((physical?'VISIBLE_REAL_CURSOR':'VISIBLE_BROWSER_POINTER')+(useRust?'_RUST':'_JS'));
 if(trace)trace.planner=useRust?'rust_goal_agent':'browser_policy';
 let s=game.snapshot();
 if(s.phase!=='planning'){
  spotlight($('reset'));log('Resetting the arena before the next operation.');await wait(260);ensureActive(id);game.reset();
 }
 spotlight($('mission'));
 s=game.snapshot();trace.mission=s.mission;
 log('OBSERVING · '+s.buildings.filter(b=>b.hp>0).length+' standing structures · Budget '+s.budget);
 const useOpenAI=$('agent-brain').value==='openai';
 spotlight($(useOpenAI?'api-plan':'local-plan'));
 if(useOpenAI){log('Requesting the opening unit mix from OpenAI.');
  const r=await game.planAI();ensureActive(id);log(r.ok?'Accepted the OpenAI unit mix':'LOCAL FALLBACK: '+r.error);
 }else{game.plan();log('The local planner chose units from the game state.');}
 await wait(250);ensureActive(id);
 if(!game.snapshot().plan?.units?.length)throw Error('No plan available');
 spotlight($('launch'));await wait(220);ensureActive(id);game.launch();
 if(game.snapshot().phase!=='deploy')throw Error('Deployment phase unverified');
 log(physical?'INPUT · Windows pointer approved':'INPUT · Browser PointerEvents');
 if(useRust){const result=await rust.start(game.snapshot());ensureActive(id);log('RUST IPC: '+result.code+' · Decisions from the Rust Goal Agent');}
 clearSpotlight();let index=0;
 while(index<24){
  ensureActive(id);
  s=game.snapshot();
  if(useRust&&!Object.values(s.plan?.remaining||{}).some(n=>n>0))break;
  const choice=useRust?(await rust.next(s)).action:policy.decideDeploy(s,index);
  ensureActive(id);if(!choice)break;
  if(choice.kind!=='deploy')throw Error('Rust returned non-deployment while units remain');
  log('DECISION '+(index+1)+': '+choice.type.toUpperCase()+' / '+choice.lane+' · '+choice.reason);
  await performDeployment(choice,id,physical);
  if(useRust){const confirmation=await rust.commit(game.snapshot());ensureActive(id);if(!confirmation.verified)throw Error('Rust readback did not verify deployment');}
  index++;
  await wait(260);ensureActive(id);
 }
 const remainder=game.snapshot().plan?.remaining||{};
 if(Object.values(remainder).some(n=>n>0))throw Error('Deployment stopped with units still in the plan');
 log('DEPLOYMENT · '+index+' units verified by ID, position, energy and counters.');
 observer('COMBAT · OBSERVING', 'Tracking HP and tactical abilities');
 let memory={lastFocusAt:-100},prev=game.snapshot(),tick=0;
 while(tick++<700){
  await wait(390);ensureActive(id);const before=game.snapshot();
  if(before.phase==='done'){
   const verified=policy.missionVerified(before);
   evidence({kind:'goal',type:'mission'},'Game outcome + authoritative building HP',prev,before,{ok:verified,code:verified?'GOAL_VERIFIED':'GOAL_FAILED'},0);
   log((verified?'OBJECTIVE VERIFIED':'DEFEAT')+' · '+before.elapsed.toFixed(1)+' s · '+before.stats.deployed+' deployments');
   if(useRust){const result=await rust.finish(before);ensureActive(id);if(Boolean(result.goal_verified)!==verified)throw Error('Rust/UI mission verification disagreement');log('RUST: '+result.code+' · '+result.verified_steps+' verified commands');}
   finishTrace('completed',verified?'verified_win':'verified_loss');return;
  }
  if(before.phase==='paused')throw Error('Battle paused');
  const action=useRust?(await rust.next(before)).action:policy.decideCombat(before,memory);ensureActive(id);
  if(action){
   const start=performance.now();let accepted=false;
   if(action.kind==='skill')accepted=game.activateSkill(action.name);
   else if(action.kind==='focus'){accepted=game.focusAt(action.x,action.y);memory.lastFocusAt=before.elapsed;}
   const after=game.snapshot();
   const proof=action.kind==='focus'?{ok:accepted&&after.focusTargetId===action.id,code:'FOCUS_READBACK'}:
    {ok:accepted&&Number(after.cooldowns?.[action.name])>Number(before.cooldowns?.[action.name]),code:'SKILL_COOLDOWN_READBACK'};
   evidence(action,action.reason,before,after,proof,performance.now()-start);
   if(!proof.ok)throw Error('UNVERIFIED: '+action.kind+'. Retry requires verification.');
   if(useRust){const ack=await rust.commit(after);ensureActive(id);if(!ack.verified)throw Error('Rust rejected combat readback');}
  }
  if(before.coreHp<=prev.coreHp-40||before.stats.lost>prev.stats.lost){
   observer('COMBAT · LIVE HP', 'Core '+Math.ceil(before.coreHp)+' HP · Allies '+before.units.length+' · Lost '+before.stats.lost);
  }
  prev=before;
 }
 throw Error('Stopped after 700 battle checks');
}
async function headless(id){
  startTrace('HEADLESS_NODE');document.body.classList.add('headless-run');
  const mission=$('mission').value;
  log('HEADLESS · Node.js runs the simulation. Chrome shows the report.');
  const ctl=new AbortController();headlessController=ctl;
  const response=await fetch('/api/agent/headless',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({mission}),signal:ctl.signal});
  ensureActive(id);
  const result=await response.json();
  if(!response.ok||!result.ok)throw Error(result.error||'Headless agent failed');
  log('HEADLESS: '+(result.verified?'OBJECTIVE VERIFIED':'OBJECTIVE MISSED')+' · '+Number(result.elapsed).toFixed(1)+' s · Energy spent '+result.spent);
  log('Engine · '+result.engine+' · Headless simulation');
  observer('HEADLESS · '+(result.verified?'VERIFIED':'FAILED'),'Result from the headless Node.js simulation.');
  finishTrace('completed',result.verified?'headless_verified':'headless_failed');
}
async function stop(){
  const had=running;
  runId++;state(false);clearSpotlight();
  headlessController?.abort();headlessController=null;
  await stopNative();
  await rust?.stop();
  game.cancelApiPlan();
  if(had){game.stop();log('Stopped by the operator. The Chrome battle is paused.');finishTrace('cancelled','user_stop');observer('STOPPED · OPERATOR','New agent actions are blocked.','error');}
  document.body.classList.remove('headless-run');
  // Server stop is restricted to the one fixed headless executable.
  try{await fetch('/api/agent/stop',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});}catch{}
}
startButton.addEventListener('click',async(event)=>{
 if(running)return;
 const visibleMode=$('agent-mode').value==='visible';
 const physical=visibleMode&&Boolean($('agent-physical')?.checked);
 if(visibleMode&&$('agent-brain').value==='openai'&&!window.confirm('Send a billable OpenAI API request?'))return;
 if(physical&&$('agent-brain').value==='openai'){log('For pointer calibration, select Local or disable the Windows pointer.');return;}
 if(physical&&!event.isTrusted){log('Click the control yourself to approve moving the Windows pointer.');return;}
 const id=++runId;state(true);log('Starting · '+$('agent-mode').selectedOptions[0].textContent);
 try{
  if(physical){
   // Calibration must happen directly after the real user click, before any waits.
   const session=await nativeCall('start',{anchor_x:Math.round(event.clientX),anchor_y:Math.round(event.clientY)});
   nativeToken=session.token;log('Windows pointer session limited to the Citadel window.');
  }
  ensureActive(id);
  if(visibleMode)await visible(id,physical);else await headless(id);
 }catch(err){if(id===runId){const msg=String(err?.message||err);log('ERROR · '+msg);finishTrace('failed','action_or_observation_failed');observer('STOPPED · FAILED',msg,'error');}}
 finally{if(id===runId){state(false);headlessController=null;clearSpotlight();document.body.classList.remove('headless-run');if(rust?.active)await rust.stop();if(physical)await stopNative();}}
});
stopButton.addEventListener('click',stop);
async function replay(){
 if(running||!lastTrace)return;
 const previous=JSON.parse(JSON.stringify(lastTrace));
 const deployment=previous.steps.filter(e=>e.action==='deploy'&&e.verified);
 if(!deployment.length)return;
 const id=++runId;state(true);startTrace('BROWSER_REPLAY');
 try{
  game.reset();if(!game.chooseMission(previous.mission))throw Error('Mission incompatible with replay');
  game.launch();if(game.snapshot().phase!=='deploy')throw Error('No deployment phase');
  for(const line of deployment){
   ensureActive(id);
   const action={kind:'deploy',type:line.type,x:line.x,y:line.y,reason:'Replay of recorded, verified placement #'+line.seq};
   log('REPLAY '+line.seq+' · '+line.type+' ['+line.x+','+line.y+']');
   await performDeployment(action,id,false);
   await wait(170);
  }
  finishTrace('completed','deployment_replay_verified');
  observer('REPLAY · VERIFIED',deployment.length+' placement actions accepted and read back; combat continues in Chrome','success');
 }catch(e){if(id===runId){finishTrace('failed','replay_failure');observer('REPLAY · FAILED',String(e.message||e),'error');log('REPLAY ERROR · '+e.message);}}
 finally{if(id===runId){state(false);clearSpotlight();}}
}
$('agent-replay').addEventListener('click',replay);

window.addEventListener('keydown',event=>{
 if(!running||!event.isTrusted)return;
 // Synthetic agent sends no keyboard input. Any real key immediately cancels it.
 stop();log('Keyboard input returned control to the operator.');
},true);
window.addEventListener('pointerdown',event=>{
 if(!running||physicalDriving||event.target===startButton||event.target===stopButton||!event.isTrusted)return;
 runId++;state(false);clearSpotlight();stopNative();rust?.stop();game.stop();finishTrace('cancelled','human_override');observer('STOPPED · PHYSICAL INPUT','Control returned to the operator.','error');log('The operator took over. The agent stopped.');
},true);

$('agent-mode').addEventListener('change',()=>{if(running)stop();log('Agent mode · '+$('agent-mode').value);});
stopButton.disabled=true;
const renderStatus=$('render-status');
let threeDStart=performance.now(),lastRenderConfirmed=0,lastRenderedUnitCount=0,ready=false,lastSent=0,seq=0,visualTimer=null;
function renderBanner(message,state='waiting'){
 if(!renderStatus)return;
 renderStatus.textContent=message;renderStatus.dataset.state=state;
}
function switchScene(){
  const mode=$('scene-mode').value;
  document.body.classList.toggle('world-3d',mode==='3d');
  document.body.classList.toggle('world-2d',mode==='2d');
  if(mode==='2d'){
    game.enable2D();renderBanner('2D · UNITS AND ATTACKS VISIBLE','ok');
  } else {
    threeDStart=performance.now();lastRenderConfirmed=0;
    renderBanner('3D · WAITING FOR FRAMES · Live tactical map active');
    sendCamera();
  }
  log('Camera · '+(mode==='3d'?'Akvarium 3D + tactical minimap':'full 2D battlefield'));
}
$('scene-mode').addEventListener('change',switchScene);
const scene=$('ocean-world');
function sendCamera(){if(scene?.contentWindow&&location.origin!=='null')scene.contentWindow.postMessage({type:'reflex-ocean-camera',preset:$('camera-distance').value},location.origin);}
$('camera-distance').addEventListener('change',()=>{sendCamera();log('Camera · '+$('camera-distance').selectedOptions[0].textContent);});
window.addEventListener('keydown',event=>{if(event.ctrlKey&&event.altKey&&event.code==='KeyP'){event.preventDefault();stop();}});
function fallbackToVisibleBattle(reason){
 if($('scene-mode').value!=='3d')return;
 $('scene-error').hidden=false;
 $('scene-error').textContent='3D unavailable · '+String(reason).slice(0,120)+' · 2D battle active';
 $('scene-mode').value='2d';switchScene();
 renderBanner('3D DISABLED · '+reason+' · 2D BATTLE VISIBLE','failed');
 log('RENDER FALLBACK · '+reason+' · Combat continues on the 2D map.');
}
scene?.addEventListener('load',()=>{
 try{const el=scene.contentDocument?.getElementById('status');
    if(el&&!el.hidden)fallbackToVisibleBattle('WebGL error · '+el.textContent.slice(0,90));
 }catch{ /* If cross-origin, rely on renderer heartbeat. */ }
});
window.addEventListener('message',event=>{
 if(event.source!==scene?.contentWindow||event.origin!==location.origin)return;
 if(event.data?.type==='reflex-ocean-ready'){
   ready=true;sendCamera();renderBanner('3D INITIALIZED · WAITING FOR FRAMES');
 }
 if(event.data?.type==='reflex-ocean-rendered'){
   if(!Number.isInteger(event.data.sequence)||event.data.sequence<=0)return;
   lastRenderConfirmed=performance.now();lastRenderedUnitCount=Number(event.data.unit_count)||0;
   if($('scene-mode').value==='3d')renderBanner('3D FRAMES ACTIVE · Units '+event.data.unit_count+' · Tactical map active','ok');
 }
 if(event.data?.type==='reflex-ocean-error')fallbackToVisibleBattle('Akvarium reported a rendering error');
});
function syncScene(){
 if($('scene-mode').value!=='3d'||!scene?.contentWindow||location.origin==='null')return;
 const t=performance.now();if(t-lastSent<110)return;lastSent=t;
 const snap=game.snapshot();
 scene.contentWindow.postMessage({type:'reflex-citadel-scene',seq:++seq,
  buildings:snap.buildings,units:snap.units,projectiles:snap.projectiles,
  effects:snap.effects,focusTargetId:snap.focusTargetId},location.origin);
}
function checkSceneHealth(){
 if($('scene-mode').value!=='3d'||document.visibilityState==='hidden')return;
 const t=performance.now();
 if(!lastRenderConfirmed&&t-threeDStart>4200){fallbackToVisibleBattle('Four seconds elapsed without a confirmed WebGL frame');return;}
 if(lastRenderConfirmed&&t-lastRenderConfirmed>3900){fallbackToVisibleBattle('The renderer stopped producing frames');}
}
visualTimer=setInterval(syncScene,120);
const visualGuard=setInterval(checkSceneHealth,950);
window.addEventListener('beforeunload',()=>clearInterval(visualGuard));
window.addEventListener('beforeunload',()=>clearInterval(visualTimer));
log('Ready. Visible mode deploys troops and verifies battle events. Moving the Windows pointer requires approval. Headless mode uses a separate Node.js process.');
})();
