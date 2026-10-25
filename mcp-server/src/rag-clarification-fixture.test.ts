// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
// Fixture integrity only: no runtime policy, semantic judge or model-quality claim.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {createHash} from 'node:crypto';
const read=name=>JSON.parse(fs.readFileSync(new URL('../scripts/rag-quality/'+name,import.meta.url),'utf8'));
const inputs=read('clarification-inputs-v1.json'),oracle=read('clarification-oracle-v1.json');
const hash=x=>createHash('sha256').update(JSON.stringify(x)).digest('hex');
const keys=(x,expected)=>assert.deepEqual(Object.keys(x).sort(),[...expected].sort());
const scope=x=>x.kind.startsWith('scope_');
test('clarification inputs keep gold and harness metadata out of the candidate input envelope',()=>{
 assert.equal(inputs.syntheticOnly,true);assert.equal(inputs.split,'separate-development-clarification');
 assert.equal(oracle.humanGoldReview,'pending');
 for(const c of inputs.cases){keys(c,['id','matrix','input','harness']);keys(c.input,['version','mode','question','contextItems']);keys(c.harness,['technicalState']);assert(!Object.hasOwn(c.input,'requirements'));assert(!Object.hasOwn(c.input,'harness'));}
});
test('clarification oracle binds every distinct mode and context to exact input bytes',()=>{
 assert.equal(inputs.cases.length,30);assert.equal(oracle.cases.length,30);
 assert.equal(new Set(inputs.cases.map(c=>c.id)).size,30);
 assert.equal(new Set(inputs.cases.map(c=>hash(c.input))).size,30);
 for(const c of inputs.cases){const o=oracle.cases.find(o=>o.id===c.id);assert(o);assert.equal(o.inputHash,hash(c.input));}
 assert.deepEqual([...new Set(inputs.cases.flatMap(c=>c.matrix))].sort((a,b)=>a-b),Array.from({length:22},(_,i)=>i+1));
});
test('clarification context availability, phase, scope and revision stay bound',()=>{
 const kinds=['user_history','scope_page','scope_notebook','scope_folder','scope_library','inspection'];
 for(const {input:i} of inputs.cases){
  assert(['question_only','contextual_pre_search','scoped_inspection'].includes(i.mode));
  assert.equal(new Set(i.contextItems.map(c=>c.id)).size,i.contextItems.length);
  if(i.mode==='question_only')assert.equal(i.contextItems.length,0);
  if(i.mode==='contextual_pre_search')assert(!i.contextItems.some(c=>c.kind==='inspection'));
  if(i.mode==='scoped_inspection'){assert(i.contextItems.some(scope));assert(i.contextItems.some(c=>c.kind==='inspection'));}
  for(const c of i.contextItems){
   keys(c,['id','kind','availability','text','revision','scopeRef','outcome']);assert.match(c.id,/^c(?:[1-9]|1[0-6])$/);assert(kinds.includes(c.kind));assert(['available','unavailable'].includes(c.availability));
   if(c.availability==='unavailable')assert.equal(c.text,'');
   if(c.kind!=='inspection'){assert.equal(c.scopeRef,null);assert.equal(c.outcome,null);continue;}
   const s=i.contextItems.find(s=>s.id===c.scopeRef&&scope(s));assert(s);assert.equal(s.revision,c.revision);
   assert(['content','no_hits','failed','unavailable'].includes(c.outcome));
   if(['content','no_hits'].includes(c.outcome)){assert.equal(s.availability,'available');assert.equal(c.availability,'available');}
   if(c.outcome==='content')assert(c.text.length>0);else assert.equal(c.text,'');
   if(['failed','unavailable'].includes(c.outcome))assert.equal(c.availability,'unavailable');
  }
 }
});
test('clarification fixture text fits planned limits without truncation or invalid Unicode',()=>{
 for(const {input:i} of inputs.cases){assert(Buffer.byteLength(i.question)<=16384);assert(i.contextItems.length<=16);assert(Buffer.byteLength(JSON.stringify(i))<=65536);
  for(const text of [i.question,...i.contextItems.map(c=>c.text)]){assert.equal(Buffer.from(text).toString('utf8'),text);assert(Buffer.byteLength(text)<=16384);}
  for(const c of i.contextItems)assert(Buffer.byteLength(c.text)<=8192);
 }
});
test('clarification oracle uses phase-appropriate tuples and available required provenance',()=>{
 for(const c of inputs.cases){const o=oracle.cases.find(o=>o.id===c.id);keys(o,['id','inputHash','technicalState','requirements']);assert.equal(o.technicalState,c.harness.technicalState);
  assert.equal(new Set(o.requirements.map(r=>r.id)).size,o.requirements.length);
  for(const r of o.requirements){assert(r.rationale.length>0);assert(r.requestLabel.length>0);assert(r.allowed.length>0);
   for(const ref of r.requiredTargetRefs)if(ref!=='q')assert(c.input.contextItems.some(x=>x.id===ref&&x.availability==='available'));
   for(const t of r.allowed){keys(t,['targetState','basis','evidenceState','nextAction','inspectionPurpose']);
    assert(['single','set','not_required','unresolved','uncertain'].includes(t.targetState));assert(['question','history','selected_scope','inspection','none'].includes(t.basis));assert(['proceed','inspect_scope','clarify_target','review_required'].includes(t.nextAction));
    assert(['not_checked','supported','insufficient','conflicting','no_hits','unavailable'].includes(t.evidenceState));
    if(t.basis==='question')assert.deepEqual(r.requiredTargetRefs,['q']);
    if(t.basis==='history')assert(r.requiredTargetRefs.some(ref=>c.input.contextItems.some(x=>x.id===ref&&x.kind==='user_history')));
    if(t.basis==='selected_scope')assert(r.requiredTargetRefs.some(ref=>c.input.contextItems.some(x=>x.id===ref&&scope(x))));
    if(t.basis==='inspection'){const obs=c.input.contextItems.find(x=>r.requiredTargetRefs.includes(x.id)&&x.kind==='inspection'&&x.outcome==='content');assert(obs);assert(r.requiredTargetRefs.includes(obs.scopeRef));}
    if(t.targetState==='not_required'){assert.equal(t.basis,'question');assert.deepEqual(r.requiredTargetRefs,['q']);}
    if(['unresolved','uncertain'].includes(t.targetState))assert.equal(t.basis,'none');
    if(c.input.mode!=='scoped_inspection')assert.equal(t.evidenceState,'not_checked');
    if(t.nextAction==='proceed')assert(['single','set','not_required'].includes(t.targetState));
    if(t.nextAction==='clarify_target')assert.equal(t.targetState,'unresolved');
    if(t.nextAction==='review_required')assert.equal(t.targetState,'uncertain');
    if(t.nextAction==='inspect_scope'){assert(c.input.contextItems.some(x=>scope(x)&&x.availability==='available'));assert.equal(t.inspectionPurpose,t.targetState==='unresolved'?'target':'content');}else assert.equal(t.inspectionPurpose,'none');
    if(t.basis==='none')assert.equal(r.requiredTargetRefs.length,0);
   }
  }
 }
});
test('clarification partial case preserves a resolved request alongside a missing target',()=>{
 const o=oracle.cases.find(c=>c.id==='clarify-partial-requests');assert.equal(o.requirements.length,2);
 assert.equal(o.requirements[0].allowed[0].nextAction,'proceed');assert.equal(o.requirements[1].allowed[0].nextAction,'clarify_target');
});
test('clarification separates page-wide content acquisition from unresolved singular target',()=>{
 const get=id=>oracle.cases.find(c=>c.id===id).requirements[0].allowed[0];
 assert.equal(get('clarify-page-summary').targetState,'set');assert.equal(get('clarify-page-summary').inspectionPurpose,'content');
 assert.equal(get('clarify-page-before').targetState,'unresolved');assert.equal(get('clarify-page-before').inspectionPurpose,'target');
});
test('clarification evaluator faults do not erase search-failure target decisions',()=>{
 const faults=oracle.cases.filter(c=>c.technicalState!=='ok');assert.equal(faults.length,2);assert(faults.every(c=>c.requirements.length===0));
 const o=oracle.cases.find(c=>c.id==='clarify-search-failed');assert.equal(o.technicalState,'ok');assert.equal(o.requirements[0].allowed[0].targetState,'single');assert.equal(o.requirements[0].allowed[0].evidenceState,'unavailable');
 assert.equal(oracle.cases.reduce((n,c)=>n+c.requirements.length,0),29);
});
