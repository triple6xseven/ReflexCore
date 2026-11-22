const vm=require('node:vm'),fs=require('fs'),assert=require('node:assert/strict');
const S=require('./strategy');
const elements={};
function element(key){if(elements[key])return elements[key];let el={id:key,value:key==='mission'?'destroy-core':'',dataset:{},className:'',disabled:false,textContent:'',hidden:false,innerHTML:'',children:[],style:{},classList:{add(){},remove(){},toggle(){}},querySelector(k){return element(key+':'+k)},addEventListener(type,fn){this[type]=fn;},click(){if(this.clickEvent)this.clickEvent();},appendChild(child){this.children.push(child);}};el.addEventListener=(type,fn)=>{el[type+'Event']=fn;};el.click=()=>el.clickEvent&&el.clickEvent();elements[key]=el;return el;}
const context2d=new Proxy({}, {get(_,key){return ()=>{};},set(_,key,value){return true;}});
const canvas={getContext(name){return name==='webgl2'?null:context2d}};
const doc={getElementById(id){return id==='terrain'||id==='battle'?canvas:element(id);},querySelector(q){if(q==='#battle'||q==='#terrain')return canvas;if(q==='.lane.active')return {dataset:{lane:'center'}};return element(q);},querySelectorAll(q){if(q==='.troop')return element('roster').children;if(q==='.lane')return ['north','center','south'].map(l=>element(l));return [];},createElement(){return element('troop'+Object.keys(elements).length)},activeElement:{tagName:'BODY'}};
let callback=null;const window={ReflexStrategy:S,addEventListener(){}},global={window,document:doc,performance:{now:()=>0},requestAnimationFrame(fn){callback=fn;},console,fetch(){throw Error('no network')},setTimeout,clearTimeout};
const source=fs.readFileSync('./game.js','utf8').replace(/\}\)\(\);\s*$/,`window.__debug={get:()=>({phase,elapsed,core:buildings.find(b=>b.type==='core').hp,units:units.length,buildings:buildings.map(b=>({type:b.type,hp:b.hp}))})};})();`);
vm.runInNewContext(source,global);
for(const mission of ['destroy-core','disable-defenses','no-giants']){
 const m=element('mission');m.value=mission;m.changeEvent();element('local-plan').click();element('launch').click();
 let now=0;for(let i=0;i<4000;i++){now+=50;callback(now);if(window.__debug.get().phase==='done')break;}
 const outcome=window.__debug.get();
 assert.equal(outcome.phase,'done');
 if(mission==='disable-defenses')assert(outcome.buildings.filter(b=>['cannon','tower'].includes(b.type)).every(b=>b.hp===0));
 else assert.equal(outcome.core,0);
 console.log(mission+': verified in '+outcome.elapsed.toFixed(1)+' sec');
 element('reset').click();
}
