'use strict';
// Non-visual regression for the Citadel 0.4.3 user-visible deployment contract.
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),S=require('./strategy');
const elements=new Map(),listeners=new Map();let idCounter=0,frame;
function el(id){
 if(elements.has(id))return elements.get(id);
 const e={id,value:id==='mission'?'destroy-core':'',dataset:{},style:{},children:[],disabled:false,hidden:false,textContent:'',innerHTML:'',
  classList:{add(){},remove(){},toggle(){}},
  setAttribute(){},querySelector(q){return el(id+':'+q);},appendChild(x){this.children.push(x);},
  getBoundingClientRect(){return {left:0,top:0,width:1024,height:640};},
  addEventListener(t,fn){this[t+'Event']=fn;},dispatchEvent(ev){this[ev.type+'Event']?.(ev);},
  click(){this.clickEvent?.();}};
 elements.set(id,e);return e;
}
const context=new Proxy({},{get(obj,p){return obj[p]||function(){};},set(obj,p,v){obj[p]=v;return true;}});
const canvas={getContext(name){return name==='webgl2'?null:context;}};
const document={body:{classList:{contains(){return false;}}},
 getElementById(id){return id==='terrain'||id==='battle'?canvas:el(id);},
 querySelector(q){if(q==='#battle'||q==='#terrain')return canvas;if(q==='.lane.active')return {dataset:{lane:'center'}};return el(q);},
 querySelectorAll(q){if(q==='.troop')return el('roster').children;if(q==='.lane')return ['north','center','south'].map(v=>el(v));return [];},
 createElement(){return el('created-'+(++idCounter));},activeElement:{tagName:'BODY'}};
const window={ReflexStrategy:S,addEventListener(t,fn){listeners.set(t,fn);},dispatchEvent(ev){listeners.get(ev.type)?.(ev);}};
const script=fs.readFileSync(require('node:path').join(__dirname,'game.js'),'utf8');
vm.runInNewContext(script,{window,document,performance:{now:()=>0},requestAnimationFrame(fn){frame=fn;},console,setTimeout,clearTimeout,encodeURIComponent,Math,Event:class Event{constructor(type){this.type=type;}}});
const game=window.ReflexCitadel;
assert(game,'Game API missing');
game.plan();assert(game.snapshot().plan,'Plan missing');
game.launch();
assert.equal(game.snapshot().phase,'deploy');
assert.equal(game.snapshot().units.length,0,'Launch must NOT automatically spawn troops');
let placement;
window.addEventListener('citadel-unit-deployed',()=>{placement=game.snapshot();});
assert.equal(game.deployAt('giant',880,318),false,'Enemy side must be blocked');
assert.equal(game.deployAt('giant',120,318),true,'Valid card should deploy');
let s=game.snapshot();
assert.equal(s.phase,'battle');assert.equal(s.units.length,1);assert.equal(s.spent,S.TYPES.giant.cost);
assert.equal(s.events.at(-1).kind,'deploy');
assert.equal(placement.units[0].x,120);
assert.equal(placement.stats.deployed,1);
assert.equal(game.deployAt('giant',140,324),true);
assert.equal(game.deployAt('giant',160,333),false,'Excess planned units must be rejected');
s=game.snapshot();for(const [type,n] of Object.entries(s.plan.remaining))for(let j=0;j<n;j++)assert(game.deployAt(type,170+j*20,166+(j%2)*30));
const lastPlacement=placement;
for(let i=1;i<1000;i++)frame(i*50);
assert.deepEqual(placement,lastPlacement);
assert.notEqual(game.snapshot().elapsed,placement.elapsed,'Capture must precede simulation advancement');
assert(game.snapshot().buildings.some(b=>b.hp<b.max),'Combat must apply damage and show changed HP');
game.reset();assert.equal(game.snapshot().phase,'planning');assert.equal(game.snapshot().units.length,0);
game.chooseMission('no-giants');game.launch();
assert.equal(game.deployAt('giant',90,200),false,'No-giants mission must reject giant');
assert.equal(game.deployAt('archer',90,200),true);
console.log('Citadel deployment: placement event and assertions passed; no invisible auto-spawn, bounded placement, mission safety, visible HP');
