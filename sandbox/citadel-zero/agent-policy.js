/* ReflexCore Citadel 0.4.5: bounded deterministic tactics over observed game state.
 * No DOM, system input, files, secrets, network or shell. Same module runs in Node.
 */
(function(root){'use strict';
const ALLOWED=['giant','archer','sapper','raider','medic'];
const COST=Object.freeze({giant:55,archer:25,sapper:40,raider:30,medic:35});
const LANES=Object.freeze({north:170,center:320,south:470});
function clamp(n,a,b){return Math.max(a,Math.min(b,n));}
function finite(n,def){return Number.isFinite(Number(n))?Number(n):def;}
function deployed(s){return Array.isArray(s?.units)?s.units:[];}
function structures(s){return Array.isArray(s?.buildings)?s.buildings.filter(b=>finite(b.hp,0)>0):[];}
function valid(s){return !!s&&['planning','deploy','battle'].includes(s.phase)&&s.plan&&s.plan.remaining;}
function liveThreat(s){return structures(s).filter(b=>['cannon','tower','core'].includes(b.type));}
function missionVerified(s){
 if(!s||s.phase!=='done')return false;
 const b=Array.isArray(s.buildings)?s.buildings:[];
 return s.mission==='disable-defenses'?b.filter(x=>['cannon','tower'].includes(x.type)).every(x=>Number(x.hp)===0):Number(s.coreHp)===0;
}
function decideDeploy(s,index=0){
 if(!valid(s)||!['deploy','battle'].includes(s.phase))return null;
 if(!Number.isInteger(index)||index<0||index>48)return null;
 const rest=s.plan.remaining,live=structures(s),ally=deployed(s),threat=liveThreat(s);
 const damaged=ally.some(u=>finite(u.max,0)>0&&u.hp/u.max<0.62);
 const walls=live.filter(b=>b.type==='wall').length;
 const score={giant:threat.length?95:40,archer:75,sapper:walls?110:28,raider:65,medic:damaged?115:30};
 if(!ally.length){score.giant+=50;score.archer+=12;}
 if(s.mission==='no-giants')score.giant=-9999;
 if(s.mission==='disable-defenses')score.archer+=30;
 const affordable=ALLOWED.filter(type=>Number.isInteger(rest[type])&&rest[type]>0&&COST[type]<=finite(s.remaining,0));
 if(!affordable.length)return null;
 const type=affordable.sort((a,b)=>score[b]-score[a]||ALLOWED.indexOf(a)-ALLOWED.indexOf(b))[0];
 // Distribute units toward living objectives; no right-side or illegal placements.
 let target;
 if(type==='sapper')target=live.find(b=>b.type==='wall')||live[0];
 else if(type==='giant')target=threat.find(b=>b.type==='cannon')||threat[0];
 else if(type==='medic'&&ally.length)target=ally.slice().sort((a,b)=>(a.hp/a.max)-(b.hp/b.max))[0];
 else target=threat.find(b=>b.type==='tower')||threat[0]||live[0];
 const base=target?finite(target.y,LANES.center):LANES.center;
 const lane=base<240?'north':base>400?'south':'center';
 const x=clamp(Math.round(100+((index*71)%170)),50,315);
 const y=clamp(Math.round(LANES[lane]+((index*37)%91)-45),50,590);
 return Object.freeze({kind:'deploy',type,x,y,lane,reason:
  type==='sapper'&&walls?'Alive walls: sapper before ranged squad':
  type==='medic'&&damaged?'Wounded allies: deploy support':
  type==='giant'?'Alive defenses: deploy tank':
  'Live enemy structures: deploy '+type});
}
function decideCombat(s,memory={}){
 if(!s||s.phase!=='battle'||!deployed(s).length)return null;
 const t=finite(s.elapsed,0),cd=s.cooldowns||{},ready=key=>t+0.0001>=finite(cd[key],0);
 if(!s.sonar&&ready('sonar')&&t>1.5&&liveThreat(s).length&&deployed(s).length>=2)
  return {kind:'skill',name:'sonar',reason:'Defenses active, EMP ready'};
 if(ready('heal')&&deployed(s).some(u=>u.max>0&&u.hp/u.max<0.55))
  return {kind:'skill',name:'heal',reason:'Ally below 55% HP, heal ready'};
 if(!s.overdrive&&ready('rage')&&(s.coreHp<350||t>=10))
  return {kind:'skill',name:'rage',reason:'Attack window, overdrive ready'};
 const threats=liveThreat(s),focus=threats.find(b=>b.type==='cannon')||threats.find(b=>b.type==='tower')||threats.find(b=>b.type==='core');
 if(focus&&s.focusTargetId!==focus.id&&t-finite(memory.lastFocusAt,-100)>=4)
  return {kind:'focus',id:focus.id,x:focus.x,y:focus.y,reason:'Prioritize active defense before core'};
 return null;
}
function proveDeploy(before,after,action){
 if(!before||!after||action?.kind!=='deploy')return {ok:false,code:'INVALID_EVIDENCE'};
 const beforeIds=new Set(deployed(before).map(u=>u.id));
 const created=deployed(after).filter(u=>!beforeIds.has(u.id)&&u.type===action.type);
 const cost=COST[action.type];
 // Count, cost, game-owned unit ID and location must all agree.
 const ids=created.filter(u=>Math.hypot(u.x-action.x,u.y-action.y)<3);
 const countOk=after.stats?.deployed===before.stats?.deployed+1;
 const energyOk=Number(after.spent)-Number(before.spent)===cost;
 const planOk=(!before.plan&&!after.plan)||after.plan?.remaining?.[action.type]===before.plan?.remaining?.[action.type]-1;
 const ok=ids.length===1&&countOk&&energyOk&&planOk;
 return {ok,code:ok?'UNIT_CREATED_VERIFIED':'DEPLOYMENT_NOT_VERIFIED',unitId:ids[0]?.id??null,energySpent:cost};
}
const api=Object.freeze({decideDeploy,decideCombat,proveDeploy,missionVerified,COST});
if(typeof module!=='undefined'&&module.exports)module.exports=api;
root.ReflexCitadelPolicy=api;
})(typeof window!=='undefined'?window:globalThis);
