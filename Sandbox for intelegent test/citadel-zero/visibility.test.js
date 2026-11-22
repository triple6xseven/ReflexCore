'use strict';
// Regression: the authoritative game must paint the fallback canvas even when 3D is selected.
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),S=require('./strategy');
const root=__dirname;
const css=fs.readFileSync(root+'/style.css','utf8');
assert(css.includes('body.world-3d #battle{display:block!important'), '3D must not hide battle tactical display');
assert(css.includes('pointer-events:none'), 'Tactical overlay must not intercept troop placement');
let clearCalls=0, unitMarks=0, callback;
const elems=new Map(),listeners=new Map();let created=0;
function el(id){if(elems.has(id))return elems.get(id);
 const e={id,value:id==='mission'?'destroy-core':'',dataset:{},style:{},children:[],disabled:false,hidden:false,checked:false,textContent:'',innerHTML:'',
  classList:{add(){},remove(){},toggle(){}},setAttribute(){},querySelector(s){return el(id+':'+s);},appendChild(x){this.children.push(x);},
  getBoundingClientRect(){return {left:0,top:0,width:1024,height:640};},
  addEventListener(t,f){this[t+'Event']=f;},dispatchEvent(ev){this[ev.type+'Event']?.(ev);},click(){this.clickEvent?.();}};
 elems.set(id,e);return e;}
const context=new Proxy({},{get(o,p){if(p==='clearRect')return ()=>{clearCalls++};if(p==='fillRect')return ()=>{unitMarks++};return o[p]||function(){}} ,set(o,p,v){o[p]=v;return true;}});
const canvas={getContext(name){return name==='webgl2'?null:context}};
const document={body:{classList:{contains(k){return k==='world-3d';}}},
 getElementById(id){return id==='battle'||id==='terrain'?canvas:el(id)},
 querySelector(q){if(q==='#battle'||q==='#terrain')return canvas;if(q==='.lane.active')return {dataset:{lane:'center'}};return el(q)},
 querySelectorAll(q){if(q==='.troop')return el('roster').children;if(q==='.lane')return ['north','center','south'].map(x=>el(x));return []},
 createElement(){return el('created-'+(++created))},activeElement:{tagName:'BODY'}};
const window={ReflexStrategy:S,addEventListener(t,f){listeners.set(t,f)}};
vm.runInNewContext(fs.readFileSync(root+'/game.js','utf8'),{
 window,document,performance:{now:()=>0},requestAnimationFrame(fn){callback=fn},console,setTimeout,clearTimeout,Math,Event:class Event{constructor(type){this.type=type}},encodeURIComponent
});
assert(window.ReflexCitadel,'Public game API');
callback(16);assert(clearCalls>0,'Authoritative tactical renderer must draw in 3D mode');
const a=clearCalls;
window.ReflexCitadel.plan();window.ReflexCitadel.launch();
assert.equal(window.ReflexCitadel.snapshot().units.length,0,'No hidden auto-spawn');
assert.equal(window.ReflexCitadel.deployAt('giant',90,140),true);
for(let i=1;i<25;i++)callback(i*50);
assert(clearCalls>a,'Tactical inset keeps updating while 3D is selected');
assert(unitMarks>0,'Visible HP and unit painting expected in tactical inset');
assert(window.ReflexCitadel.snapshot().stats.deployed===1);
console.log('Citadel visibility: 3D tactical inset painting, manual placement, no auto-spawn PASSED');
