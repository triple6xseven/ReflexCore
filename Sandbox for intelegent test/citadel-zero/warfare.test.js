'use strict';
// Real game-loop regression with an isolated DOM; never dispatches Windows input.
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),S=require('./strategy');
const elements={};let frame=null,created=0;
const elem=id=>elements[id]||(elements[id]={id,dataset:{},value:id==='mission'?'destroy-core':'',style:{},disabled:false,hidden:false,innerHTML:'',textContent:'',children:[],
  classList:{add(){},remove(){},toggle(){}},
  setAttribute(){},appendChild(x){this.children.push(x);},querySelector(q){return elem(id+q)},
  addEventListener(type,fn){this[type+'Event']=fn;},dispatchEvent(e){this[e.type+'Event']?.(e);},click(){this.clickEvent?.();},getBoundingClientRect(){return {left:0,top:0,width:1024,height:640};}});
const ctx=new Proxy({}, {get(){return ()=>{}}});
const canvas={getContext(type){return type==='webgl2'?null:ctx;}};
const document={
 getElementById:id=>['terrain','battle'].includes(id)?canvas:elem(id),
 querySelector:q=>['#terrain','#battle'].includes(q)?canvas:q==='.lane.active'?{dataset:{lane:'center'}}:elem(q),
 querySelectorAll:q=>q==='.troop'?elem('roster').children:q==='.lane'?['north','center','south'].map(elem):[],
 createElement:()=>elem('new'+(++created)),activeElement:{tagName:'BODY'},body:{classList:{add(){},remove(){},contains(){return false;}}}
};
const window={ReflexStrategy:S,addEventListener(){}};
const code=fs.readFileSync(__dirname+'/game.js','utf8');
vm.runInNewContext(code,{window,document,console,performance:{now(){return 0}},requestAnimationFrame(fn){frame=fn},setTimeout,clearTimeout,Event:class Event{constructor(type){this.type=type}}});
const game=window.ReflexCitadel;
assert(game);
assert.equal(game.activateSkill('sonar'),false,'No unit => no skill');
game.plan();game.launch();
assert.equal(game.snapshot().units.length,0,'Launch never secretly spawns');
assert(game.deployAt('giant',125,176));
assert(game.activateSkill('sonar'),'EMP sonar ability must activate with a deployed unit');
assert(game.snapshot().sonar);assert(game.snapshot().effects.some(e=>e.kind==='sonar'));
assert.equal(game.activateSkill('sonar'),false,'Cooldown must be enforced');
assert(game.focusAt(880,356),'Focus priority should select target building');
assert.equal(game.snapshot().focusTargetId,'core');
assert.equal(game.focusAt(8,12),false,'Arbitrary point may not select distant building');
assert(game.activateSkill('rage'));assert(game.snapshot().overdrive);
const healed=game.activateSkill('heal');assert(healed);
assert.equal(game.snapshot().stats.deployed,1);
assert(game.snapshot().events.some(x=>x.kind==='deploy'),'Expected visible deployment log');
for(let i=1;i<=1300;i++)frame(i*50);
let snap=game.snapshot();
assert(snap.stats.damage>0,'Combat damage must actually result from impact');
assert(snap.buildings.some(b=>b.hp<b.max),'Expected HP change from actual attack');
assert(snap.effects.length<=90,'FX bounded');
assert(snap.projectiles.length<=150,'Projectiles bounded');
game.reset();snap=game.snapshot();
assert.equal(snap.stats.damage,0);assert.equal(snap.units.length,0);assert.equal(snap.focusTargetId,null);
console.log('Citadel warfare: abilities, cooldown, priority targets, verified damage, VFX caps, reset PASSED');
