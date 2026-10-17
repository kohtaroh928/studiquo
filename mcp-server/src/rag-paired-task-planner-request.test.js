import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {pairedTaskPlannerRequest,pairedTaskPlannerManifest} from '../scripts/rag-quality/paired-task-planner-request.mjs';
import {taskPlannerRequest,taskPlannerRequestManifest} from '../scripts/rag-quality/task-planner-request.mjs';
const hash=x=>createHash('sha256').update(x).digest('hex');
const draft=JSON.parse(readFileSync(new URL('../scripts/rag-quality/task-plan-paired-draft.json',import.meta.url)));

test('each pair changes only fixed instructions and sends question alone without oracle data',()=>{
 for(let i=0;i<8;i++){
  const baseline=pairedTaskPlannerRequest(i,'baseline'),candidate=pairedTaskPlannerRequest(i,'candidate');
  const {instructions:a,...one}=baseline,{instructions:b,...two}=candidate;
  assert.deepEqual(one,two);assert.equal(a,taskPlannerRequest(0).instructions);assert.ok(b.startsWith(a));
  assert.equal((b.slice(a.length).match(/^\d\. /gm)||[]).length,5);
  assert.deepEqual(one.input,[{role:'user',content:[{type:'input_text',text:JSON.stringify({question:draft.cases[i].question})}]}]);
  assert.ok(!JSON.stringify(candidate).includes(draft.cases[i].id));
  assert.equal(one.model,'gpt-6-luna');assert.equal(one.store,false);assert.equal(one.stream,false);assert.equal(one.max_output_tokens,8192);
  assert.ok(Buffer.byteLength(JSON.stringify(candidate))<=24576);
 }
 const source=readFileSync(new URL('../scripts/rag-quality/paired-task-planner-request.mjs',import.meta.url),'utf8');
 assert.ok(!source.includes('.declaredScopes'));assert.ok(!source.includes('paired-oracle'));assert.ok(!source.includes('evaluation-50'));
});
test('only fixed variant and integer indices are accepted and returned clones cannot alter inputs',()=>{
 for(const i of [-1,8,0.2,'0',null,undefined,{},NaN])assert.throws(()=>pairedTaskPlannerRequest(i,'baseline'));
 for(const v of ['current','',{},null,undefined])assert.throws(()=>pairedTaskPlannerRequest(0,v));
 assert.throws(()=>pairedTaskPlannerRequest(0,'candidate',{}));assert.throws(()=>pairedTaskPlannerManifest('override'));
 const original=pairedTaskPlannerManifest();const body=pairedTaskPlannerRequest(0,'candidate');
 body.instructions='override';body.input[0].content[0].text='override';body.text.format.schema.properties.tasks.maxItems=999;
 const m=pairedTaskPlannerManifest();m.rows[0].requestHash='override';assert.deepEqual(pairedTaskPlannerManifest(),original);
});
test('all sixteen request hashes are reproducible without question text in manifest',()=>{
 const m=pairedTaskPlannerManifest();assert.equal(m.rows.length,16);assert.equal(m.externalCalls,0);assert.equal(m.modelEvaluated,false);assert.equal(m.releaseAccepted,false);
 for(const row of m.rows)assert.equal(row.requestHash,hash(JSON.stringify(pairedTaskPlannerRequest(row.index,row.variant))));
 for(const c of draft.cases)assert.ok(!JSON.stringify(m).includes(c.question));
});
test('original six bodies and reviewed source hashes remain unchanged',()=>{
 const r=JSON.parse(readFileSync(new URL('../../docs/RAG_TASK_PLANNER_LIVE_RESULTS.json',import.meta.url)));
 for(const [file,h]of Object.entries(r.sourceHashes))assert.equal(hash(readFileSync(new URL('../scripts/rag-quality/'+file,import.meta.url))),h);
 const old=taskPlannerRequestManifest();assert.equal(old.questionCount,6);
 for(const row of old.rows)assert.equal(row.requestHash,hash(JSON.stringify(taskPlannerRequest(row.index))));
});
