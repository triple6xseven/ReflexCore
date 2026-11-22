const assert = require('node:assert/strict');
const S = require('./strategy');
for(const mission of ['destroy-core','disable-defenses','no-giants']) {
  const p = S.localPlan({mission,budget:260,buildings:[]});
  assert(p.spent <= 260);
  assert(p.units.length > 0);
  if(mission === 'no-giants') assert(!p.units.some(x=>x.type==='giant'));
}
assert.throws(()=>S.validatePlan({units:[{type:'giant',count:2,lane:'north'}]},30,'destroy-core'));
assert.throws(()=>S.validatePlan({units:[{type:'archer',count:500,lane:'north'}]},260,'destroy-core'));
const allowed=S.validatePlan({units:[{type:'archer',count:4,lane:'north'},{type:'giant',count:2,lane:'center'}]},260,'no-giants');
assert(allowed.units.every(x=>x.type!=='giant'));
assert.equal(S.extractPlanText('```json\n{"units":[{"type":"archer","count":2,"lane":"north"}]}\n```').units[0].type,'archer');
assert.equal(S.safeMission('evil'),'destroy-core');
console.log('Reflex Citadel strategy: 9 checks passed');
