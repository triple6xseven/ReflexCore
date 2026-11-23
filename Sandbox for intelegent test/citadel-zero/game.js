(()=>{'use strict';
const S=window.ReflexStrategy,T=S.TYPES;
const W=1024,H=640,board=document.querySelector('#battle'),ctx=board.getContext('2d');
const $=id=>document.getElementById(id);
const lanes={north:166,center:318,south:475};
const colors={core:'#fa7378',cannon:'#e4a56b',tower:'#b5c6ff',wall:'#718e81'};
const rnd=(a,b)=>Math.random()*(b-a)+a,clamp=(v,a,b)=>Math.max(a,Math.min(v,b));
let buildings=[],units=[],particles=[],sparks=[],projectiles=[],combatEvents=[],plan=null,manual=[],budget=260,spent=0,phase='planning',mission='destroy-core',elapsed=0,spawned=false,last=performance.now(),fpsAvg=60,serverReady=false;
let selectedType=null,planRemaining=null,nextUnitId=0,dropPreview=null;
// 0.4.4: all combat effects are derived from actual state changes, never fake damage.
let effects=[],floaters=[],focusTargetId=null,battleSpeed=1,overdriveUntil=0,sonarUntil=0;
let soundEnabled=false,audioCtx=null,lastAudioTime=-999;
function sound(kind){
 if(!soundEnabled)return;
 try{
  const AudioContext=window.AudioContext||window.webkitAudioContext;if(!AudioContext)return;
  if(!audioCtx)audioCtx=new AudioContext();
  const t=audioCtx.currentTime;if(t-lastAudioTime<.035)return;lastAudioTime=t;
  const osc=audioCtx.createOscillator(),gain=audioCtx.createGain();
  const pitch=kind==='explosion'?82:kind==='sonar'?320:kind==='heal'?560:kind==='buff'?170:250;
  osc.type=kind==='explosion'?'sawtooth':kind==='sonar'?'sine':'triangle';
  osc.frequency.setValueAtTime(pitch,t);osc.frequency.exponentialRampToValueAtTime(Math.max(30,pitch*.42),t+.21);
  gain.gain.setValueAtTime(.0001,t);gain.gain.exponentialRampToValueAtTime(.022,t+.012);
  gain.gain.exponentialRampToValueAtTime(.0001,t+.24);
  osc.connect(gain);gain.connect(audioCtx.destination);osc.start(t);osc.stop(t+.25);
 }catch{}
}
let abilityReady={sonar:0,heal:0,rage:0},stats={deployed:0,lost:0,damage:0,healed:0,shots:0,destroyed:0};
const ABILITIES=Object.freeze({sonar:{cooldown:16},heal:{cooldown:25},rage:{cooldown:30}});
function fx(x,y,kind,color='#b9fff3',intensity=1){
 effects.push({x,y,kind,color,age:0,life:kind==='explosion'?1.5:kind==='sonar'?1.4:.7,intensity});
 if(effects.length>90)effects.splice(0,effects.length-90);
 if(['explosion','sonar','heal','buff'].includes(kind))sound(kind);
}
function floating(x,y,text,color='#ffffff'){
 floaters.push({x,y,text:String(text).slice(0,14),age:0,life:1.25,color});
 if(floaters.length>75)floaters.splice(0,floaters.length-75);
}
function hudAbilities(){
 for(const key of Object.keys(ABILITIES)){
  const b=$('skill-'+key);if(!b)continue;
  const left=Math.max(0,abilityReady[key]-elapsed);
  b.disabled=!['battle','deploy'].includes(phase)||units.length===0||left>0;
  b.querySelector?.('.cooldown')?.replaceChildren?.(document.createTextNode(left>0?Math.ceil(left)+'s':'READY'));
 }
 const indicator=$('target-indicator');if(indicator){const b=buildings.find(x=>x.id===focusTargetId&&x.hp>0);indicator.textContent=b?'TARGET · '+b.type.toUpperCase()+' · '+Math.ceil(b.hp)+' HP':'TARGET · AUTO';}
}
function activateSkill(which){
 if(!ABILITIES[which]||!['deploy','battle'].includes(phase)||!units.some(u=>u.hp>0)||elapsed<abilityReady[which])return false;
 abilityReady[which]=elapsed+ABILITIES[which].cooldown;
 if(which==='sonar'){
   sonarUntil=elapsed+2.8;
   for(const b of buildings)if(b.hp>0&&b.dmg>0)b.disabledUntil=Math.max(b.disabledUntil||0,sonarUntil);
   fx(490,310,'sonar','#67f9ff',1.5);eventLog('SONAR EMP · Towers stunned for 2.8 s','skill');
 }else if(which==='heal'){
   let amount=0;
   for(const u of units){if(u.hp<=0)continue;const heal=Math.min(u.max-u.hp,Math.max(24,Math.round(u.max*.17)));u.hp+=heal;amount+=heal;fx(u.x,u.y,'heal','#90ffe3',.8);floating(u.x,u.y-25,'+'+Math.round(heal),'#96ffe7');}
   stats.healed+=amount;eventLog('TIDAL REPAIR · Restored '+Math.round(amount)+' HP','skill');
 }else{
   overdriveUntil=elapsed+8;
   for(const u of units)fx(u.x,u.y,'buff','#ffd36f',.75);
   eventLog('OVERDRIVE · Attack boosted for eight seconds','skill');
 }
 hudAbilities();return true;
}
function focusAt(x,y){
 let candidate=null,distanceMin=65;
 for(const b of buildings)if(b.hp>0){const dist=Math.hypot(b.x-x,b.y-y);if(dist<distanceMin){distanceMin=dist;candidate=b;}}
 if(!candidate)return false;
 focusTargetId=candidate.id;fx(candidate.x,candidate.y,'target','#ffe88c');eventLog('FOCUS FIRE · '+candidate.type.toUpperCase(),'order');return true;
}

function initialBuildings(){return[
 {id:'wall-n',type:'wall',x:640,y:170,r:30,max:240,hp:240,range:0,dmg:0,reload:0},
 {id:'wall-s',type:'wall',x:638,y:467,r:30,max:240,hp:240,range:0,dmg:0,reload:0},
 {id:'cannon-n',type:'cannon',x:760,y:163,r:30,max:210,hp:210,range:189,dmg:23,reload:0},
 {id:'cannon-s',type:'cannon',x:765,y:470,r:30,max:210,hp:210,range:189,dmg:23,reload:0},
 {id:'tower',type:'tower',x:892,y:260,r:30,max:160,hp:160,range:180,dmg:13,reload:0},
 {id:'core',type:'core',x:880,y:356,r:48,max:480,hp:480,range:140,dmg:11,reload:0}
];}
// Original troop portrait SVG artwork, local-only and independent of third-party game assets.
const portraitStyle={
 giant:{bg:'#4f7152',skin:'#d5a377',hair:'#d4b55f',coat:'#6c8d3f',tool:'hammer'},
 archer:{bg:'#255c56',skin:'#e9b98f',hair:'#e55d86',coat:'#398b69',tool:'bow'},
 sapper:{bg:'#866143',skin:'#e2a46b',hair:'#b58c53',coat:'#af6b37',tool:'bomb'},
 raider:{bg:'#783f50',skin:'#d39c78',hair:'#28293a',coat:'#a64f57',tool:'sword'},
 medic:{bg:'#535387',skin:'#f0c5aa',hair:'#c4b3ef',coat:'#8568aa',tool:'staff'}
};
function portrait(type){
 const c=portraitStyle[type],tool={hammer:'<path d="M69 35v45" stroke="#f8df9b" stroke-width="6"/><rect x="56" y="25" width="26" height="18" rx="5" fill="#adb9b2"/>',bow:'<path d="M73 22 Q95 49 73 83 M73 22 L73 83" fill="none" stroke="#f4cb78" stroke-width="4"/>',bomb:'<circle cx="73" cy="69" r="14" fill="#3e4647" stroke="#f8c262" stroke-width="3"/><path d="M70 56l9-11" stroke="#f9b754" stroke-width="3"/>',sword:'<path d="M72 20L83 63L73 71Z" fill="#cce6eb"/><path d="M65 65L87 63" stroke="#ffe8a5" stroke-width="5"/>',staff:'<path d="M75 25L76 84" stroke="#d1b7ff" stroke-width="6"/><circle cx="75" cy="21" r="10" fill="#c8f8dd"/>'}[c.tool];
 const face=type==='giant'?'<path d="M30 48q16 19 30 0l-3 19q-12 10-22-2z" fill="#a76a38"/>':'<path d="M37 55q9 7 18 0" fill="none" stroke="#895d55" stroke-width="2"/>';
 const hood=type==='archer'?'<path d="M22 47Q17 6 46 8Q73 10 69 48L59 33Q43 20 31 35Z" fill="#245b4e" stroke="#71d9ad" stroke-width="3"/>':`<path d="M25 30Q31 7 48 10Q65 9 67 35L59 28L50 24L34 30Z" fill="${c.hair}"/>`;
 const glasses=type==='sapper'?'<rect x="28" y="31" width="34" height="11" rx="4" fill="#343b43" stroke="#f4e1a3" stroke-width="3"/>':'<circle cx="36" cy="38" r="2.7" fill="#2a272b"/><circle cx="52" cy="38" r="2.7" fill="#2a272b"/>';
 const svg=`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 96"><defs><radialGradient id="b"><stop stop-color="#86c4a8"/><stop offset="1" stop-color="${c.bg}"/></radialGradient></defs><rect width="96" height="96" rx="13" fill="url(#b)"/><circle cx="80" cy="12" r="23" fill="#ffffff" opacity=".08"/><path d="M12 96Q9 71 27 63L60 62Q80 68 81 96" fill="${c.coat}" stroke="#293e39" stroke-width="3"/><path d="M32 64l12 12 14-13" fill="none" stroke="#e6c58a" stroke-width="5"/><ellipse cx="45" cy="40" rx="24" ry="29" fill="${c.skin}" stroke="#755d49" stroke-width="2"/>${hood}${glasses}${face}${tool}<path d="M8 85Q38 79 90 90" fill="none" stroke="#ffffff" stroke-opacity=".12" stroke-width="7"/></svg>`;
 return 'data:image/svg+xml;charset=utf-8,'+encodeURIComponent(svg);
}
const side=$('roster');Object.keys(T).forEach((k,i)=>{
 const b=document.createElement('button');b.className='troop';b.dataset.type=k;b.setAttribute('aria-label',T[k].label+' — '+T[k].cost+' energy');
 b.innerHTML=`<img class="portrait" draggable="false" src="${portrait(k)}" alt=""><span class="troop-meta"><span class="name">${T[k].label}</span><span class="type">${T[k].role}</span><span class="troop-stats">❤ ${T[k].hp}　⚔ ${T[k].dmg}</span></span><span class="count">0</span><span class="cost">◈ ${T[k].cost}</span>`;
 b.addEventListener('click',()=>selectCard(k));side.appendChild(b);
});
function eventLog(text,kind='note'){
 combatEvents.push({time:elapsed,message:String(text).slice(0,120),kind});if(combatEvents.length>400)combatEvents.shift();
 const feed=$('combat-feed');if(feed)feed.textContent=combatEvents.slice(-9).map(e=>`${e.time.toFixed(1).padStart(5,' ')}s  ${e.message}`).join('\n');
}
function selectCard(type){
 if(!['planning','deploy','battle'].includes(phase))return false;
 if(mission==='no-giants'&&type==='giant'){message('This mission excludes giants.');return false;}
 if(spent+T[type].cost>budget){message('Insufficient energy.');return false;}
 if(planRemaining&&(!planRemaining[type]||planRemaining[type]<=0)){message('No cards of this unit type remain in the plan.');return false;}
 selectedType=type;drawPlan('DEPLOY');return true;
}
function boardPoint(clientX,clientY){
 const r=$('deployment-layer').getBoundingClientRect();if(!r.width||!r.height)return null;
 return {x:(clientX-r.left)*W/r.width,y:(clientY-r.top)*H/r.height};
}
function deployAt(type,x,y,source='PLAYER'){
 if(!['deploy','battle'].includes(phase))return false;
 if(!T[type]||!Number.isFinite(x)||!Number.isFinite(y)||x<35||x>370||y<25||y>H-25)return false;
 if(mission==='no-giants'&&type==='giant'||spent+T[type].cost>budget)return false;
 if(planRemaining&&!(planRemaining[type]>0))return false;
 const t=T[type];spent+=t.cost;if(planRemaining)planRemaining[type]--;
 const u={id:++nextUnitId,type,x,y,hp:t.hp,max:t.hp,attack:.12,deployDelay:.15,selected:false,anim:'deploy',attackPose:.6,hurt:0,walk:0,heading:0};
 units.push(u);spawned=true;phase='battle';
 if($('launch'))$('launch').textContent='DEPLOYING · DRAG CARDS';
 $('ai-status').textContent='● LIVE COMBAT';
 stats.deployed++;fx(x,y,'deploy',t.color);eventLog(source+' → '+t.label+' ['+Math.round(x)+','+Math.round(y)+']','deploy');
 hit(x,y,t.color,12);drawPlan('DEPLOY');return true;
}
let pointerDrag=null;
const zone=$('deployment-layer');
function beginDrag(type,e){
 if(!['planning','deploy','battle'].includes(phase))return;
 if(!selectCard(type))return;
 if(phase==='planning')startDeployment();
 pointerDrag={type,pointerId:e.pointerId};dropPreview=null;
 document.body.classList.add('dragging-troop');
 const ghost=$('drag-ghost');if(ghost){ghost.src=portrait(type);ghost.hidden=false;ghost.style.left=e.clientX+'px';ghost.style.top=e.clientY+'px';}
 try{e.currentTarget?.setPointerCapture?.(e.pointerId);}catch{}
 e.preventDefault?.();
}
function pointerMove(e){if(!pointerDrag)return;const ghost=$('drag-ghost');if(ghost){ghost.style.left=e.clientX+'px';ghost.style.top=e.clientY+'px';}dropPreview=boardPoint(e.clientX,e.clientY);}
function endDrag(e){
 if(!pointerDrag)return;
 const type=pointerDrag.type;pointerDrag=null;document.body.classList.remove('dragging-troop');const ghost=$('drag-ghost');if(ghost)ghost.hidden=true;
 const p=boardPoint(e.clientX,e.clientY);dropPreview=null;
 if(!p||!deployAt(type,p.x,p.y,'MOUSE'))message('Deploy units on the left side of the map.');
}
for(const b of side.children){b.addEventListener('pointerdown',e=>beginDrag(b.dataset.type,e));}
window.addEventListener('pointermove',pointerMove);
window.addEventListener('pointerup',endDrag);
window.addEventListener('pointercancel',()=>{pointerDrag=null;dropPreview=null;document.body.classList.remove('dragging-troop');const g=$('drag-ghost');if(g)g.hidden=true;});
zone?.addEventListener('click',e=>{
 const p=boardPoint(e.clientX,e.clientY);if(!p)return;
 if(p.x>370){if(['battle','deploy'].includes(phase))focusAt(p.x,p.y);return;}
 if(!selectedType)return;if(phase==='planning')startDeployment();
 if(!deployAt(selectedType,p.x,p.y,'CLICK'))message('Place units in the highlighted zone on the left.');
});
function startDeployment(){
 if(phase!=='planning')return false;phase='deploy';$('ai-status').textContent='● SELECT A CARD / DRAG TO DEPLOY';$('launch').textContent='DRAG CARDS TO DEPLOY';
 $('mission').disabled=true;$('local-plan').disabled=true;$('api-plan').disabled=true;
 eventLog('Deployment started. Drag a card to the left side of the map.');return true;
}
function initTerrain(){const c=$('terrain');const gl=c.getContext('webgl2',{alpha:false,antialias:false});if(!gl){const d=c.getContext('2d');if(d){d.fillStyle='#1a3430';d.fillRect(0,0,W,H);for(let i=0;i<950;i++){d.fillStyle=i%2?'#26483a':'#18362d';d.fillRect((i*91)%W,(i*127)%H,3,3);}}return;}
const vs=`#version 300 es\nin vec2 p;out vec2 v;void main(){v=p*.5+.5;gl_Position=vec4(p,0.,1.);}`;
const fs=`#version 300 es\nprecision highp float;in vec2 v;out vec4 outColor;uniform float time;
float hash(vec2 p){return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453);}
float noise(vec2 p){vec2 i=floor(p),f=fract(p);f=f*f*(3.-2.*f);return mix(mix(hash(i),hash(i+vec2(1,0)),f.x),mix(hash(i+vec2(0,1)),hash(i+vec2(1,1)),f.x),f.y);}
float fbm(vec2 p){float a=.5,r=0.;for(int i=0;i<5;i++){r+=a*noise(p);p=p*2.07+17.1;a*=.5;}return r;}
void main(){vec2 uv=v;uv.y=1.-uv.y;vec2 p=uv*vec2(11.0,7.0);float n=fbm(p),fine=noise(p*12.);vec2 g=abs(fract(p*1.18)-.5);float grid=1.-smoothstep(.013,.029,min(g.x,g.y));
float rocky=smoothstep(.48,.77,n),patch=smoothstep(.24,.72,noise(p*.55));vec3 grass=mix(vec3(.052,.128,.117),vec3(.126,.226,.165),n);
grass=mix(grass,vec3(.17,.22,.18),rocky*.35);grass=mix(grass,vec3(.085,.11,.11),smoothstep(.15,.85,abs(uv.y-.5))* .19);
vec3 color=grass+(.025* fine)+grid*.015;
float line=(1.-smoothstep(.0,.08,abs(uv.x-.53)))*0.05;color=mix(color,vec3(.20,.21,.17),line);
float deploy=1.-smoothstep(.1,.17,uv.x);color+=deploy*vec3(.005,.13,.08)*(0.75+0.25*sin(time*1.5));
float border=smoothstep(.0,.014,uv.x)+smoothstep(.0,.014,1.-uv.x)+smoothstep(.0,.014,uv.y)+smoothstep(.0,.014,1.-uv.y);color*=clamp(border,.66,1.);
outColor=vec4(color,1.);}`;
function shader(type,src){const s=gl.createShader(type);gl.shaderSource(s,src);gl.compileShader(s);if(!gl.getShaderParameter(s,gl.COMPILE_STATUS))throw Error(gl.getShaderInfoLog(s));return s;}
try{const pr=gl.createProgram();gl.attachShader(pr,shader(gl.VERTEX_SHADER,vs));gl.attachShader(pr,shader(gl.FRAGMENT_SHADER,fs));gl.linkProgram(pr);if(!gl.getProgramParameter(pr,gl.LINK_STATUS))throw Error(gl.getProgramInfoLog(pr));const buf=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,buf);gl.bufferData(gl.ARRAY_BUFFER,new Float32Array([-1,-1,1,-1,-1,1,1,1]),gl.STATIC_DRAW);const pos=gl.getAttribLocation(pr,'p');gl.enableVertexAttribArray(pos);gl.vertexAttribPointer(pos,2,gl.FLOAT,false,0,0);const u=gl.getUniformLocation(pr,'time');function paint(){gl.viewport(0,0,c.width,c.height);gl.useProgram(pr);gl.uniform1f(u,elapsed);gl.drawArrays(gl.TRIANGLE_STRIP,0,4);requestAnimationFrame(paint);}requestAnimationFrame(paint);}catch(e){console.warn('GLSL shader fallback',e);gl.clearColor(.06,.16,.13,1);gl.clear(gl.COLOR_BUFFER_BIT);}}
function addManual(type){selectCard(type);}
function setPlan(p,origin){
 if(phase!=='planning')return false;
 plan=S.validatePlan(p,budget,mission);manual=[];planRemaining={};
 for(const q of plan.units)planRemaining[q.type]=(planRemaining[q.type]||0)+q.count;
 drawPlan(origin);return true;
}
function drawPlan(origin){
 const counts=planRemaining||{};
 document.querySelectorAll('.troop').forEach(b=>{
  const type=b.dataset.type,available=planRemaining?Number(counts[type]||0):Math.floor((budget-spent)/T[type].cost);
  b.querySelector('.count').textContent=planRemaining?String(available):'+';
  b.classList.toggle('selected',selectedType===type);
  b.disabled=(phase==='done'||phase==='paused'||available<=0||(mission==='no-giants'&&type==='giant'));
 });
 $('energy').textContent=String(budget-spent);
 $('plan').textContent=plan?`${origin} · ${plan.spent} energy planned · ${spent} deployed\n${plan.units.map(x=>`${x.type.toUpperCase()} ×${counts[x.type]||0} remaining`).join(' · ')}\n${plan.reason}`:
  `${budget-spent} energy. Drag a card into the deployment zone on the left.`;
}
function message(text){$('plan').textContent=String(text).slice(0,400);}
function setMission(){if(phase!=='planning')return;mission=S.safeMission($('mission').value);$('objective-text').textContent=mission==='no-giants'?'Destroy the core without giants':mission==='disable-defenses'?'Destroy the defense towers':'Destroy the enemy core';plan=null;planRemaining=null;manual=[];selectedType=null;drawPlan('');}
$('mission').addEventListener('change',setMission);
document.querySelectorAll('.lane').forEach(b=>b.addEventListener('click',()=>{document.querySelectorAll('.lane').forEach(x=>x.classList.remove('active'));b.classList.add('active');}));
$('local-plan').addEventListener('click',()=>{if(phase!=='planning')return;setPlan(S.localPlan({mission,budget,buildings}), 'LOCAL TACTICIAN');$('ai-status').textContent='● LOCAL TACTICIAN';});
async function requestAPIPlan(){
  if(phase!=='planning')return {ok:false,provider:'none',error:'Battle not in planning phase'};
  const button=$('api-plan');button.disabled=true;
  $('ai-status').textContent='◌ OPENAI THINKING';message('Sending the game state to OpenAI. The API key stays on the server.');
  const controller=new AbortController();apiRequestController=controller;
  const timeout=setTimeout(()=>controller.abort(),45000);
  try{
    const body=JSON.stringify({mission,instructions:$('instructions').value.slice(0,400),state:S.stateDigest({mission,budget,buildings})});
    const res=await fetch('/api/plan',{method:'POST',headers:{'Content-Type':'application/json'},body,signal:controller.signal});
    const answer=await res.json();if(!res.ok||!answer.ok)throw Error(answer.error||'OpenAI is unavailable');
    setPlan(S.extractPlanText(answer.plan),'OPENAI AGENT');$('ai-status').textContent='✧ OPENAI STRATEGIST';
    return {ok:true,provider:'openai',model:answer.model||'configured'};
  }catch(e){
    setPlan(S.localPlan({mission,budget,buildings}),'OFFLINE FALLBACK');
    $('ai-status').textContent='● LOCAL FALLBACK';message('API ERROR: '+e.message+'\nSwitched to the local planner.');
    return {ok:false,provider:'local-fallback',error:String(e.message).slice(0,200)};
  }finally{clearTimeout(timeout);if(apiRequestController===controller)apiRequestController=null;button.disabled=false;}
}
$('api-plan').addEventListener('click',requestAPIPlan);
$('launch').addEventListener('click',()=>{startDeployment();});
$('reset').addEventListener('click',reset);$('again').addEventListener('click',reset);$('pause').addEventListener('click',()=>{if(phase==='battle'){phase='paused';$('pause').textContent='▶ RESUME';}else if(phase==='paused'){phase='battle';$('pause').textContent='Ⅱ PAUSE';}});
window.addEventListener('keydown',e=>{
 if(e.target&&['TEXTAREA','INPUT','SELECT'].includes(e.target.tagName))return;
 if(e.key==='Escape')$('pause').click();if(e.key.toLowerCase()==='r')reset();
 if(e.key.toLowerCase()==='q')activateSkill('sonar');
 if(e.key.toLowerCase()==='e')activateSkill('heal');
 if(e.key.toLowerCase()==='f')activateSkill('rage');
 if(e.key.toLowerCase()==='x'){focusTargetId=null;eventLog('Targeting set to auto','order');}
 if(phase==='planning'&&!['TEXTAREA','INPUT','SELECT'].includes(document.activeElement?.tagName)&&/^[1-5]$/.test(e.key))addManual(Object.keys(T)[Number(e.key)-1]);});
function reset(){
 buildings=initialBuildings();units=[];particles=[];sparks=[];projectiles=[];combatEvents=[];plan=null;planRemaining=null;manual=[];selectedType=null;dropPreview=null;spent=0;phase='planning';elapsed=0;spawned=false;nextUnitId=0;
 $('result').hidden=true;$('launch').disabled=false;$('launch').textContent='START DEPLOYMENT →';$('mission').disabled=false;$('local-plan').disabled=false;$('api-plan').disabled=false;$('pause').textContent='Ⅱ PAUSE';$('ai-status').textContent='● AWAITING DEPLOYMENT';
 effects=[];floaters=[];focusTargetId=null;overdriveUntil=0;sonarUntil=0;battleSpeed=1;if($('speed-control'))$('speed-control').value='1';abilityReady={sonar:0,heal:0,rage:0};stats={deployed:0,lost:0,damage:0,healed:0,shots:0,destroyed:0};
 const report=$('battle-summary');if(report)report.textContent='Deploy troops to see battle statistics.';
 const feed=$('combat-feed');if(feed)feed.textContent='Awaiting deployment.';
 drawPlan('');setMission();
}
// The visible UI never spawns troops automatically on launch.
// Explicitly named deterministic deployment exists for headless simulator tests only.
function deployPlannedForHeadless(){
 if(!plan)return false;startDeployment();let i=0;
 for(const q of plan.units)for(let j=0;j<q.count;j++){
  const x=80+(i%3)*42,y=clamp(lanes[q.lane]+(i%4-1.5)*14,35,H-35);
  if(!deployAt(q.type,x,y,'HEADLESS'))return false;i++;
 }
 return i>0;
}
function distance(a,b){return Math.hypot(a.x-b.x,a.y-b.y);}
function hit(x,y,color,n=8){for(let i=0;i<n;i++)particles.push({x,y,vx:rnd(-55,55),vy:rnd(-55,55),life:rnd(.3,.85),max:.9,color});if(particles.length>260)particles.splice(0,particles.length-260);}
function selectTarget(u){const live=buildings.filter(b=>b.hp>0);if(!live.length)return null;const typ=u.type;
// Threat suppression: tank engages anti-troop towers; sapper prioritizes walls.
const focused=live.find(b=>b.id===focusTargetId);
 if(focused&&u.type!=='sapper')return focused;
 const sorted=live.map(b=>({b,score:distance(u,b)-((typ==='giant'&&['cannon','tower'].includes(b.type))?160:0)-((typ==='sapper'&&b.type==='wall')?280:0)-((typ==='archer'&&b.type==='cannon')?70:0)})).sort((a,b)=>a.score-b.score);return sorted[0].b;}
function applyImpact(p){
 const target=p.target;if(!target||target.hp<=0)return;
 if(p.heal){const actual=Math.min(target.max-target.hp,p.damage);target.hp+=actual;stats.healed+=actual;hit(target.x,target.y,'#8df6dc',7);fx(target.x,target.y,'heal','#8df6dc');floating(target.x,target.y-25,'+'+Math.round(actual),'#8df6dc');return;}
 const actual=Math.min(target.hp,p.damage);target.hp-=actual;target.hurt=.35;
 if(p.source&&T[p.source.type]&&target.max>0&&!T[target.type])stats.damage+=actual;
 hit(target.x,target.y,p.color,p.kind==='bomb'?16:7);
 fx(target.x,target.y,p.kind==='bomb'||p.kind==='cannon'?'explosion':'impact',p.color,p.kind==='bomb'?1.6:1);
 floating(target.x,target.y-27,'−'+Math.round(actual),p.color);
 if(target.hp===0){hit(target.x,target.y,p.color,32);fx(target.x,target.y,'explosion',p.color,2.4);stats.destroyed+=T[target.type]?0:1;eventLog((target.type||'UNIT').toUpperCase()+' destroyed','destroy');}
 else eventLog((p.source?.type||'DEFENSE').toUpperCase()+' → '+(target.type||'UNIT').toUpperCase()+' −'+Math.round(actual)+' HP','hit');
}
function fire(from,target,damage,kind,color,speed=420,heal=false){
 projectiles.push({x:from.x,y:from.y,z:0,from:{x:from.x,y:from.y},source:from,target,damage,kind,color,speed,heal,life:0});
 stats.shots++;if(kind==='bomb'||kind==='cannon')fx(from.x,from.y,'muzzle',color,.8);
 if(projectiles.length>150)projectiles.splice(0,projectiles.length-150);
}
function update(dt){
 elapsed+=dt;const living=units.filter(x=>x.hp>0);
 for(const u of living){
  u.attackPose=Math.max(0,(u.attackPose||0)-dt*2.7);u.hurt=Math.max(0,(u.hurt||0)-dt);
  if(u.deployDelay>0){u.deployDelay-=dt;u.anim='deploy';continue;}
  const t=T[u.type];u.attack-=dt;
  if(u.type==='medic'){
   const ally=living.filter(a=>a!==u&&a.hp<a.max).sort((a,b)=>distance(u,a)-distance(u,b))[0];
   if(!ally){u.anim='idle';continue;}
   const d=Math.max(.001,distance(u,ally));u.heading=Math.atan2(ally.y-u.y,ally.x-u.x);
   if(d>t.range*.73){u.x+=(ally.x-u.x)/d*t.speed*dt;u.y+=(ally.y-u.y)/d*t.speed*dt;u.anim='walk';u.walk+=dt*12;}
   else if(u.attack<=0){fire(u,ally,34,'heal','#8df9df',480,true);u.attack=t.interval;u.anim='attack';u.attackPose=1;}
   else u.anim='idle';continue;
  }
  const target=selectTarget(u);if(!target){u.anim='idle';continue;}
  const d=Math.max(.001,distance(u,target));u.heading=Math.atan2(target.y-u.y,target.x-u.x);
  if(d>t.range+target.r*.42){u.x+=(target.x-u.x)/d*t.speed*dt;u.y+=(target.y-u.y)/d*t.speed*dt;u.anim='walk';u.walk+=dt*12;}
  else if(u.attack<=0){
   const damage=t.dmg*(u.type==='sapper'&&target.type==='wall'?1.7:1)*(elapsed<overdriveUntil?1.4:1);
   u.attack=t.interval;u.anim='attack';u.attackPose=1;
   if(['archer','sapper'].includes(u.type))fire(u,target,damage,u.type==='sapper'?'bomb':'arrow',t.color,u.type==='sapper'?300:540);
   else{applyImpact({target,damage,color:t.color,kind:'melee',source:u});if(u.type==='sapper')u.hp=Math.max(0,u.hp-8);}
  }else u.anim='idle';
 }
 // Defensive buildings have visible wind-up, tracked targets and projectiles.
 for(const b of buildings){
  b.hurt=Math.max(0,(b.hurt||0)-dt);b.flash=Math.max(0,(b.flash||0)-dt);
  if(b.hp<=0||b.dmg<=0)continue;if(elapsed<(b.disabledUntil||0))continue;b.reload-=dt;let closest=null,best=Infinity;
  for(const u of living){if(u.deployDelay>0||u.hp<=0)continue;const d=distance(u,b);if(d<best&&d<b.range){best=d;closest=u;}}
  if(closest){b.angle=Math.atan2(closest.y-b.y,closest.x-b.x);}
  if(closest&&b.reload<=0){
   fire(b,closest,b.dmg,b.type==='cannon'?'cannon':'bolt',colors[b.type],b.type==='cannon'?290:470);
   b.reload=b.type==='cannon'?1.4:b.type==='tower'?.87:1.2;b.flash=.35;
  }
 }
 for(const p of projectiles){
  p.life+=dt;const t=p.target;
  if(!t||t.hp<=0){p.done=true;continue;}
  const dx=t.x-p.x,dy=t.y-p.y,d=Math.hypot(dx,dy);
  if(d<Math.max(8,p.speed*dt)){p.x=t.x;p.y=t.y;applyImpact(p);p.done=true;}
  else{p.x+=dx/d*p.speed*dt;p.y+=dy/d*p.speed*dt;}
  if(p.life>3)p.done=true;
 }
 projectiles=projectiles.filter(p=>!p.done);
 const fallen=units.filter(u=>u.hp<=0);
 for(const u of fallen){fx(u.x,u.y,'fall',T[u.type].color,1.25);stats.lost++;eventLog(T[u.type].label+' lost','loss');}
 units=units.filter(u=>u.hp>0);
 particles.forEach(p=>{p.life-=dt;p.x+=p.vx*dt;p.y+=p.vy*dt;p.vx*=.97;p.vy*=.97;});particles=particles.filter(p=>p.life>0);
 sparks.forEach(s=>s.life-=dt);sparks=sparks.filter(s=>s.life>0);
 effects.forEach(e=>e.age+=dt);effects=effects.filter(e=>e.age<e.life);
 floaters.forEach(e=>e.age+=dt);floaters=floaters.filter(e=>e.age<e.life);
 const won=mission==='disable-defenses'?buildings.filter(b=>['cannon','tower'].includes(b.type)).every(b=>b.hp<=0):buildings.find(b=>b.type==='core').hp<=0;
 if(won)return finish(true);
 const remaining=planRemaining?Object.values(planRemaining).reduce((a,b)=>a+b,0):Math.floor((budget-spent)/Math.min(...Object.values(T).map(v=>v.cost)));
 if(elapsed>150||(spawned&&units.length===0&&remaining<=0))return finish(false);
}
function finish(win){phase='done';$('result').hidden=false;
 const summary=$('battle-summary');if(summary)summary.textContent=`Deployed: ${stats.deployed}  ·  Lost: ${stats.lost}  ·  Damage: ${Math.round(stats.damage)} HP  ·  Healing: ${Math.round(stats.healed)} HP  ·  Destroyed: ${stats.destroyed}`;
 eventLog(win?'OBJECTIVE VERIFIED':'MISSION FAILED','result');$('result-title').textContent=win?'VICTORY':'DEFEAT';$('result-title').style.color=win?'#b6ff63':'#ff786b';$('result-message').textContent=win?`Objective verified · ${elapsed.toFixed(1)} s · ${spent} energy spent`:'Squad lost. Change the unit mix and try again.';$('ai-status').textContent=win?'● OBJECTIVE VERIFIED':'● MISSION FAILED';}
function line(x1,y1,x2,y2){ctx.moveTo(x1,y1);ctx.lineTo(x2,y2);}
function poly(x,y,r,n,phase=0){ctx.beginPath();for(let i=0;i<n;i++){let a=i*Math.PI*2/n+phase,xx=x+Math.cos(a)*r,yy=y+Math.sin(a)*r;if(i===0)ctx.moveTo(xx,yy);else ctx.lineTo(xx,yy);}ctx.closePath();}
function hpBar(x,y,w,ratio,color,label){
 ctx.save();ctx.fillStyle='#061013d9';ctx.fillRect(x-w/2-2,y-2,w+4,11);
 ctx.fillStyle='#1c2829';ctx.fillRect(x-w/2,y,w,7);ctx.fillStyle=ratio>.55?'#75ed87':ratio>.24?'#ffd06f':'#ff7168';
 ctx.fillRect(x-w/2,y,w*clamp(ratio,0,1),7);ctx.strokeStyle='#d1f7e478';ctx.strokeRect(x-w/2,y,w,7);
 if(label){ctx.textAlign='center';ctx.font='bold 10px Consolas';ctx.fillStyle='#f3ffe8';ctx.fillText(label,x,y-7);}
 ctx.restore();
}
function building(b){
 const alive=b.hp>0,glow=colors[b.type];ctx.save();ctx.translate(b.x,b.y);
 if(!alive){ctx.fillStyle='#273235';poly(0,0,b.r,7);ctx.fill();ctx.strokeStyle='#47505a';ctx.lineWidth=3;ctx.stroke();ctx.restore();return;}
 ctx.shadowColor=glow;ctx.shadowBlur=b.type==='core'?27:10;ctx.fillStyle='#1b2d34';ctx.strokeStyle=glow;ctx.lineWidth=4;
 poly(0,0,b.r,8,Math.PI/8);ctx.fill();ctx.stroke();ctx.shadowBlur=0;
 ctx.save();ctx.rotate(b.angle||0);ctx.fillStyle=b.flash>0?'#fff4c2':glow;
 if(b.type==='cannon'){ctx.fillRect(-9,-13,28,26);ctx.fillRect(12,-7,26,14);ctx.strokeStyle='#172224';ctx.lineWidth=4;ctx.strokeRect(-7,-11,25,22);}
 else if(b.type==='tower'){ctx.fillRect(-12,-10,24,20);poly(14,0,13,3);ctx.fill();}
 else if(b.type==='core'){ctx.rotate(elapsed*.4);poly(0,0,b.r*.68,6,Math.PI/6);ctx.fill();ctx.fillStyle='#ffe4d2';poly(0,0,b.r*.25,4);ctx.fill();}
 else{ctx.fillRect(-b.r*.75,-10,b.r*1.5,20);ctx.strokeStyle='#b3d9cb';ctx.strokeRect(-b.r*.75,-10,b.r*1.5,20);}
 ctx.restore();
 if(b.hurt>0){ctx.strokeStyle='#fff6d7';ctx.lineWidth=5;poly(0,0,b.r+5,8);ctx.stroke();}
 ctx.restore();hpBar(b.x,b.y-b.r-12,Math.max(48,b.r*1.8),b.hp/b.max,glow,`${b.type.toUpperCase()}  ${Math.ceil(b.hp)}/${b.max}`);
}
function troop(u){
 const t=T[u.type],size=u.type==='giant'?16:11;ctx.save();ctx.translate(u.x,u.y);ctx.rotate(u.heading||0);
 if(u.deployDelay>0)ctx.globalAlpha=.4;
 const bob=u.anim==='walk'?Math.sin(u.walk)*2:0;
 ctx.shadowColor=t.color;ctx.shadowBlur=9;ctx.fillStyle=u.hurt>0?'#fff2d8':'#203038';ctx.strokeStyle=t.color;ctx.lineWidth=2.7;
 ctx.beginPath();ctx.ellipse(0,0,size,size*.85,0,0,Math.PI*2);ctx.fill();ctx.stroke();ctx.shadowBlur=0;
 ctx.fillStyle=t.color;ctx.fillRect(-size*.46,-size*.5+bob,size*.85,size*.95);
 ctx.fillStyle='#efc49a';ctx.beginPath();ctx.arc(size*.4,0,size*.4,0,Math.PI*2);ctx.fill();
 const swing=(u.attackPose||0)*13;
 ctx.strokeStyle=u.type==='archer'?'#d8efdc':'#ffe6ab';ctx.lineWidth=u.type==='giant'?6:3;
 ctx.beginPath();line(4,-size*.5,9+swing,-size*.75);ctx.stroke();
 if(u.type==='archer'){ctx.strokeStyle='#d3c391';ctx.beginPath();ctx.arc(size*.8,0,size*.7,-1.5,1.5);ctx.stroke();}
 else if(u.type==='sapper'){ctx.fillStyle='#fcad39';ctx.beginPath();ctx.arc(size,0,5,0,Math.PI*2);ctx.fill();}
 else if(u.type==='medic'){ctx.strokeStyle='#a4f8e1';ctx.lineWidth=3;ctx.beginPath();line(4,0,18+swing,0);ctx.stroke();}
 else if(u.type==='raider'){ctx.strokeStyle='#f1eddf';ctx.lineWidth=4;ctx.beginPath();line(5,0,20+swing,0);ctx.stroke();}
 ctx.restore();hpBar(u.x,u.y-size-25,35,u.hp/u.max,t.color,`${Math.ceil(u.hp)} HP`);
}
function draw(){
 ctx.clearRect(0,0,W,H);ctx.save();ctx.strokeStyle='#45ea9950';ctx.setLineDash([5,8]);ctx.beginPath();line(370,0,370,H);ctx.stroke();ctx.setLineDash([]);
 ctx.fillStyle='#35e5aa13';ctx.fillRect(0,0,370,H);
 ctx.font='bold 14px Consolas';ctx.textAlign='left';ctx.fillStyle='#a5f8d9';ctx.fillText('DEPLOY ZONE',20,31);
 for(const b of buildings)building(b);
 for(const p of projectiles){ctx.strokeStyle=p.color;ctx.lineWidth=p.kind==='cannon'?5:2;ctx.shadowColor=p.color;ctx.shadowBlur=16;ctx.beginPath();line(p.x-12,p.y,p.x,p.y);ctx.stroke();ctx.shadowBlur=0;ctx.fillStyle=p.color;ctx.beginPath();ctx.arc(p.x,p.y,p.kind==='bomb'?8:4,0,7);ctx.fill();}
 for(const s of sparks){ctx.globalAlpha=Math.max(0,s.life/.17);ctx.strokeStyle=s.color;ctx.lineWidth=2;ctx.beginPath();line(s.a.x,s.a.y,s.b.x,s.b.y);ctx.stroke();}ctx.globalAlpha=1;
 for(const u of units)troop(u);
 for(const p of particles){ctx.globalAlpha=clamp(p.life/p.max,0,1);ctx.fillStyle=p.color;ctx.fillRect(p.x,p.y,4,4);}ctx.globalAlpha=1;
 for(const e of effects){const t=e.age/e.life,r=8+e.intensity*t*58;ctx.strokeStyle=e.color;ctx.globalAlpha=(1-t)*.8;ctx.lineWidth=e.kind==='explosion'?5:2;ctx.beginPath();ctx.arc(e.x,e.y,r,0,Math.PI*2);ctx.stroke();}
 ctx.globalAlpha=1;
 for(const f of floaters){const t=f.age/f.life;ctx.globalAlpha=(1-t);ctx.textAlign='center';ctx.font='900 18px Consolas';ctx.strokeStyle='#07171de6';ctx.lineWidth=4;ctx.strokeText(f.text,f.x,f.y-t*35);ctx.fillStyle=f.color;ctx.fillText(f.text,f.x,f.y-t*35);}ctx.globalAlpha=1;
 if(focusTargetId){const b=buildings.find(x=>x.id===focusTargetId&&x.hp>0);if(b){ctx.strokeStyle='#fff3a0';ctx.lineWidth=4;ctx.beginPath();ctx.arc(b.x,b.y,b.r+14+Math.sin(elapsed*5)*4,0,7);ctx.stroke();}}
 if(dropPreview){ctx.fillStyle=dropPreview.x<=370?'#83ffd450':'#ff686850';ctx.beginPath();ctx.arc(dropPreview.x,dropPreview.y,27,0,7);ctx.fill();}
 ctx.restore();
}
let lastReadout=0;
function updateReadout(){
 const names={core:'CORE',cannon:'CANNON',tower:'TOWER',wall:'WALL'};
 const str=$('structure-status'),squad=$('squad-status');
 if(str)str.textContent=buildings.map(b=>`${(names[b.type]||b.type).padEnd(7,' ')} ${String(Math.ceil(b.hp)).padStart(3,' ')}/${b.max}`).join('\n');
 if(squad){
  const byType={};for(const u of units){const v=byType[u.type]||(byType[u.type]={n:0,hp:0,max:0});v.n++;v.hp+=u.hp;v.max+=u.max;}
  squad.textContent=Object.entries(byType).map(([k,v])=>`${k.toUpperCase()} ×${v.n}  ${Math.ceil(v.hp)}/${v.max}`).join('\n')||'AWAITING DEPLOYMENT';
 }
}
function loop(now){let dt=clamp((now-last)/1000,0,.07);last=now;
 if(now-lastReadout>180){updateReadout();hudAbilities();lastReadout=now;}fpsAvg=fpsAvg*.96+(1/Math.max(dt,.005))*.04;if(phase==='battle')update(dt*battleSpeed);draw();$('wave').textContent='01';$('corehp').textContent=Math.ceil(100*buildings.find(b=>b.type==='core').hp/480)+'%';$('timer').textContent=Math.floor(elapsed/60)+':'+String(Math.floor(elapsed%60)).padStart(2,'0');$('fps').textContent=Math.round(fpsAvg)+' FPS';requestAnimationFrame(loop);}
// Structured read-only observations and bounded UI actions for Reflex Agent.
let terrainReady=false;
let apiRequestController=null;
window.ReflexCitadel=Object.freeze({
 enable2D:()=>{if(!terrainReady){terrainReady=true;initTerrain();}},
 snapshot:()=>({phase,mission,elapsed,spent,budget,remaining:budget-spent,selectedType,coreHp:buildings.find(b=>b.type==='core').hp,
   plan:plan?{units:plan.units.map(q=>({...q})),remaining:{...planRemaining}}:null,
   buildings:buildings.map(b=>({id:b.id,type:b.type,x:b.x,y:b.y,hp:b.hp,max:b.max,r:b.r,flash:b.flash||0,hurt:b.hurt||0,angle:b.angle||0})),
   units:units.map(u=>({id:u.id,type:u.type,x:u.x,y:u.y,hp:u.hp,max:u.max,deployDelay:u.deployDelay,anim:u.anim,attackPose:u.attackPose,heading:u.heading,walk:u.walk,hurt:u.hurt})),
   projectiles:projectiles.map(p=>({x:p.x,y:p.y,kind:p.kind,color:p.color,life:p.life})),
   effects:effects.map(e=>({x:e.x,y:e.y,kind:e.kind,age:e.age,life:e.life,intensity:e.intensity,color:e.color})),
   focusTargetId, stats:{...stats}, cooldowns:{...abilityReady}, overdrive:elapsed<overdriveUntil, sonar:elapsed<sonarUntil, speed:battleSpeed,
   events:combatEvents.slice(-12).map(e=>({...e}))}),
 chooseMission:(value)=>{if(phase!=='planning')return false;$('mission').value=S.safeMission(value);$('mission').dispatchEvent(new Event('change'));return true;},
 reset:()=>{$('reset').click();},
 plan:()=>{$('local-plan').click();},
 planAI:()=>requestAPIPlan(),
 cancelApiPlan:()=>apiRequestController?.abort(),
 launch:()=>startDeployment(),
 selectCard,
 deployAt,
 deployPlannedForHeadless,
 activateSkill,focusAt,
 stop:()=>{if(phase==='battle')$('pause').click();},
 resume:()=>{if(phase==='paused')$('pause').click();}
});
for(const key of Object.keys(ABILITIES))$('skill-'+key)?.addEventListener('click',()=>activateSkill(key));
$('target-clear')?.addEventListener('click',()=>{focusTargetId=null;eventLog('Target priority cleared','order');});
$('sound-enabled')?.addEventListener('change',()=>{soundEnabled=Boolean($('sound-enabled').checked);if(soundEnabled)sound('sonar');});
$('export-report')?.addEventListener('click',()=>{
 const report={schema:'reflexcore.citadel.combat-report.v1',mission,result:phase,elapsed_seconds:Number(elapsed.toFixed(2)),
  spent,budget,stats:{...stats},buildings:buildings.map(b=>({id:b.id,type:b.type,hp:Math.ceil(b.hp),max:b.max})),
  events:combatEvents.map(e=>({...e}))};
 const blob=new Blob([JSON.stringify(report,null,2)],{type:'application/json'});
 const url=URL.createObjectURL(blob);
 const a=document.createElement('a');a.href=url;a.download='citadel-combat-'+Date.now()+'.json';
 document.body.appendChild(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),5000);
 eventLog('Battle report exported locally','control');
});
$('target-list')?.querySelectorAll?.('[data-target]')?.forEach(button=>{
 button.addEventListener('click',()=>{const b=buildings.find(x=>x.id===button.dataset.target&&x.hp>0);if(b)focusAt(b.x,b.y);});
});
$('speed-control')?.addEventListener('change',()=>{const value=Number($('speed-control').value);if([.5,1,1.5,2].includes(value)){battleSpeed=value;eventLog('Simulation speed '+value+'×','control');}});
if(!document.getElementById('ocean-world'))initTerrain();reset();requestAnimationFrame(loop);
})();
