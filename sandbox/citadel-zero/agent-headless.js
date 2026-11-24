'use strict';
// Fixed-scope headless runner: no browser, no network, no shell, no user-controlled paths.
const fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const S=require('./strategy');
const allowed=['destroy-core','disable-defenses','no-giants'];
const arg=process.argv.find(v=>v.startsWith('--mission='));
const mission=arg?arg.slice('--mission='.length):'destroy-core';
if(!allowed.includes(mission)){console.error('Invalid mission');process.exit(2);}
function run(mission){
  const elements={};let callback=null;let n=0;
  function el(key){
    if(elements[key])return elements[key];
    const e={id:key,value:key==='mission'?'destroy-core':'',dataset:{},disabled:false,textContent:'',hidden:false,
      innerHTML:'',children:[],style:{},classList:{add(){},remove(){},toggle(){},contains(){return false}},
      querySelector(k){return el(key+':'+k);},addEventListener(type,fn){this[type+'Event']=fn;},
      setAttribute(){},dispatchEvent(evt){const fn=this[evt.type+'Event'];if(fn)fn();},
      click(){if(this.clickEvent)this.clickEvent();},appendChild(child){this.children.push(child);}};
    elements[key]=e;return e;
  }
  const ctx2d=new Proxy({},{get(_t,key){return ()=>{};},set(){return true;}});
  const canvas={getContext(name){return name==='webgl2'?null:ctx2d}};
  const doc={getElementById(id){return id==='terrain'||id==='battle'?canvas:el(id);},
    querySelector(q){if(q==='#battle'||q==='#terrain')return canvas;if(q==='.lane.active')return {dataset:{lane:'center'}};return el(q);},
    querySelectorAll(q){if(q==='.troop')return el('roster').children;if(q==='.lane')return ['north','center','south'].map(x=>el(x));return [];},
    createElement(){return el('troop'+(++n));},activeElement:{tagName:'BODY'}};
  const win={ReflexStrategy:S,addEventListener(){}};
  const seed={value:271828};
  const rand=()=>{seed.value=(Math.imul(seed.value,1664525)+1013904223)>>>0;return seed.value/4294967296;};
  const math=Object.create(Math);math.random=rand;
  const ctx={window:win,document:doc,performance:{now:()=>0},requestAnimationFrame(fn){callback=fn;},console,
    Math:math,fetch(){throw Error('Unexpected network')},setTimeout,clearTimeout};
  const source=fs.readFileSync(path.join(__dirname,'game.js'),'utf8');
  const end=/\}\)\(\);\s*$/;
  if(!end.test(source))throw Error('Game entrypoint changed');
  const decorated=source.replace(end,`window.__headless={get:()=>({phase,elapsed,spent,mission,coreHp:buildings.find(b=>b.type==='core').hp,buildings:buildings.map(b=>({type:b.type,hp:b.hp})),units:units.length})};})();`);
  vm.runInNewContext(decorated,ctx,{filename:'game.js',timeout:2000});
  el('mission').value=mission;el('mission').changeEvent();el('local-plan').click();el('launch').click();
  if(!win.ReflexCitadel.deployPlannedForHeadless())throw Error('Headless deployment failed');
  let current=0;
  for(let i=0;i<4000;i++){
    current+=50;callback(current);
    if(win.__headless.get().phase==='done')break;
  }
  const result=win.__headless.get();
  const verified=result.phase==='done'&&(mission==='disable-defenses'
    ?result.buildings.filter(b=>['cannon','tower'].includes(b.type)).every(b=>b.hp===0)
    :result.coreHp===0);
  return {ok:true,schema:'reflexcore.citadel.headless.v1',engine:'Node.js VM deterministic game simulation',
    mission,verified,elapsed:result.elapsed,spent:result.spent,remainingUnits:result.units};
}
try{const result=run(mission);process.stdout.write(JSON.stringify(result)+'\n');if(!result.verified)process.exitCode=3;}
catch(error){console.error(error.message);process.exitCode=1;}
