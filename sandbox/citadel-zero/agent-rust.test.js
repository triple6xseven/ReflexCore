'use strict';
// Wire protocol client test only. No Windows/Chrome, no claimed physical input.
const assert=require('node:assert/strict');
const fixtureSessionId='0123456789abcdef'.repeat(2);
const client=require('./agent-rust');
const calls=[];
const initial={phase:'deploy',mission:'destroy-core',elapsed:0,budget:260,spent:0,remaining:260,coreHp:480,
 plan:{remaining:{giant:1,archer:0,sapper:0,raider:0,medic:0}},
 buildings:[{id:'core',type:'core',x:880,y:356,hp:480,max:480,private:'must_not_leave_browser'}],units:[],
 stats:{deployed:0,lost:0,damage:0,private:'must_not_leave_browser'},cooldowns:{sonar:0,heal:0,rage:0},
 sonar:false,overdrive:false,focusTargetId:null,events:[{message:'must_not_leave_browser'}]};
global.fetch=async (url,options)=>{
 calls.push({url,body:options.body});
 if(url.endsWith('/stop'))return {ok:true,json:async()=>({ok:true})};
 const req=JSON.parse(options.body);
 const result={schema:'reflexcore.citadel.bridge.v1',ok:true};
 if(url.endsWith('/start'))result.token=fixtureSessionId;
 if(url.endsWith('/next'))result.action={kind:'deploy',type:'giant',x:120,y:170,lane:'north',reason:'Rust goal planner'};
 if(url.endsWith('/commit'))result.verified=true;
 if(url.endsWith('/finish'))result.goal_verified=true;
 return {ok:true,json:async()=>result};
};
(async()=>{
 assert.equal(client.active,false);
 await client.start(initial);assert.equal(client.active,true);
 const action=(await client.next(initial)).action;
 assert.equal(action.type,'giant');assert.equal(action.x,120);
 assert.equal((await client.commit(initial)).verified,true);
 const finished=await client.finish({...initial,phase:'done',coreHp:0});assert(finished.goal_verified);
 assert.equal(calls.length,4);
 assert.deepEqual(calls.map(x=>JSON.parse(x.body).seq),[1,2,3,4]);
 assert(!calls.some(x=>x.body.includes('must_not_leave_browser')),'Browser-only metadata should never cross Rust IPC');
 assert.equal(JSON.parse(calls[0].body).token,undefined);
 assert.equal(JSON.parse(calls[1].body).token,fixtureSessionId);
 await client.stop();assert.equal(client.active,false);
 console.log('Citadel Rust client: bounded world projection, session sequence and stop PASSED (mocked HTTP)');
})().catch(e=>{console.error(e);process.exitCode=1;});
