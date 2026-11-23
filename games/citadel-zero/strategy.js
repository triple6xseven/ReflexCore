(function (g) {
'use strict';
const TYPES = Object.freeze({
 giant:{cost:55,hp:480,dmg:24,range:23,speed:23,interval:0.8,color:'#a9e66a',label:'GIANT',role:'Tank / towers'},
 archer:{cost:25,hp:115,dmg:23,range:148,speed:35,interval:0.67,color:'#38edc9',label:'ARCHER',role:'Ranged attack'},
 sapper:{cost:40,hp:115,dmg:105,range:22,speed:58,interval:1.4,color:'#f9c36f',label:'SAPPER',role:'Explosives / walls'},
 raider:{cost:30,hp:195,dmg:34,range:24,speed:48,interval:0.73,color:'#f28b91',label:'RAIDER',role:'Fast assault'},
 medic:{cost:35,hp:160,dmg:0,range:130,speed:36,interval:0.7,color:'#b1abff',label:'MEDIC',role:'Squad healing'}
});
function safeMission(s){return ['destroy-core','disable-defenses','no-giants'].includes(s)?s:'destroy-core';}
function stateDigest(s){return {mission:safeMission(s.mission),budget:Math.max(0,Math.min(260,Number(s.budget)||0)),buildings:Array.isArray(s.buildings)?s.buildings.filter(b=>b && ['core','cannon','tower','wall'].includes(b.type)).slice(0,12).map(b=>({type:b.type,hp:Math.max(0,Number(b.hp)||0),x:Number(b.x)||0,y:Number(b.y)||0})):[]};}
function localPlan(state){
  const mission=safeMission(state.mission),budget=state.budget;
  const compositions=mission==='disable-defenses'
   ?[{type:'giant',count:2,lane:'center'},{type:'archer',count:4,lane:'north'},{type:'sapper',count:1,lane:'south'}]
   :mission==='no-giants'
   ?[{type:'raider',count:3,lane:'center'},{type:'archer',count:4,lane:'north'},{type:'sapper',count:1,lane:'south'}]
   :[{type:'giant',count:2,lane:'center'},{type:'archer',count:4,lane:'north'},{type:'sapper',count:1,lane:'south'}];
  return validatePlan({units:compositions,reason: mission==='no-giants'?'Without giants, use fast units, ranged attacks, and a sapper.':'Giants draw tower fire, archers attack defenses, and the sapper breaches walls.'},budget,mission);
}
function validatePlan(plan,budget,mission){
  if(!plan||typeof plan!=='object'||!Array.isArray(plan.units))throw Error('Invalid plan. Expected a units array.');
  const out=[];let spent=0,total=0;
  for(const raw of plan.units.slice(0,18)){
    const type=String(raw?.type||'').toLowerCase(); if(!TYPES[type])continue;
    if(safeMission(mission)==='no-giants'&&type==='giant')continue;
    const count=Number(raw.count);if(!Number.isInteger(count)||count<1||count>12)continue;
    const lane=['north','center','south'].includes(raw.lane)?raw.lane:'center';
    const can=Math.min(count,Math.floor((budget-spent)/TYPES[type].cost),24-total);
    if(can<=0)continue;spent+=can*TYPES[type].cost;total+=can;out.push({type,count:can,lane});
  }
  if(!out.length)throw Error('The plan has no valid units within budget.');
  return {units:out,spent,reason:String(plan.reason||'Plan ready').slice(0,160)};
}
function extractPlanText(s){
  if(typeof s!=='string')throw Error('Empty model response');
  s=s.trim().replace(/^```(?:json)?\s*/i,'').replace(/\s*```$/,'');
  const a=s.indexOf('{'),b=s.lastIndexOf('}');if(a<0||b<=a)throw Error('The model response had no JSON.');
  return JSON.parse(s.slice(a,b+1));
}
const api={TYPES,safeMission,stateDigest,localPlan,validatePlan,extractPlanText};
if(typeof module!=='undefined'&&module.exports)module.exports=api;
g.ReflexStrategy=api;
})(typeof window!=='undefined'?window:globalThis);
