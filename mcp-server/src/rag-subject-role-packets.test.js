import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {subjectRolePairedLedgerManifest as manifest} from '../scripts/rag-quality/subject-role-paired-ledger.mjs';
import {subjectRoleTaskPlannerRequest as request} from '../scripts/rag-quality/subject-role-task-planner-request.mjs';
import {parseSubjectRoleTaskPlannerResponse as parse} from '../scripts/rag-quality/subject-role-task-planner-response.mjs';
import {createSubjectRoleReviewPackets as create,verifySubjectRoleReviewPackets as verify,resolveSubjectRoleReviewSubmission as resolve} from '../scripts/rag-quality/subject-role-review-packets.mjs';
const hash=x=>createHash('sha256').update(x).digest('hex');
const encode=r=>r.map(JSON.stringify).join('\n')+'\n';
const append=(rows,event)=>rows.push({...event,previous:hash(JSON.stringify(rows.at(-1)))});
function ledger(){
 const m=manifest(),rows=[{type:'manifest',manifest:m,runId:'aa000000-0000-4000-8000-000000000000',previous:null}];
 for(const job of m.jobs.slice(0,2)){
  append(rows,{type:'reserved',job,reservedMicroUSD:8192});
  const q=JSON.parse(request(job.index,job.variant).input[0].content[0].text);
  const plan={version:4,questionHash:q.questionHash,status:'candidate',unresolved:[],tasks:[{id:'t1',operation:'value',attribute:{label:'synthetic property',unitIds:['u1']},subjects:[],conditions:[],requestUnitIds:['u1'],resolution:'unknown',evidenceSupport:'unknown',comparisonPermission:'unknown'}]};
  const raw=JSON.stringify({object:'response',status:'completed',error:null,incomplete_details:null,model:request(job.index,job.variant).model,output:[{type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:JSON.stringify(plan)}]}],usage:{input_tokens:100,output_tokens:100,total_tokens:200,output_tokens_details:{reasoning_tokens:10}}});
  append(rows,{type:'completed',ordinal:job.ordinal,result:parse(job.index,job.variant,job.requestHash,raw),elapsedMs:1});
 }
 append(rows,{type:'stage_finished',stage:0,completedRequests:2,completedPairs:1});return encode(rows);
}
const error=e=>e.message==='subject_role_packets_audit_required';
test('neutral packets keep question plan provenance and oracle but omit arm identity and instructions',()=>{
 const raw=ledger(),c=create(raw);assert.equal(c.packets.length,2);assert.equal(c.mapping.length,2);assert.equal(c.reviewGateAttached,false);assert.equal(c.releaseAccepted,false);assert.deepEqual(verify(raw,JSON.stringify(c)),c);
 assert.deepEqual(c.packets.map(p=>p.packetId),c.packets.map(p=>p.packetId).sort());
 for(const p of c.packets){assert.deepEqual(Object.keys(p),['packetId','question','plan','structuralProvenance','oracle']);assert.equal(Object.hasOwn(p,'variant'),false);assert.equal(Object.hasOwn(p,'instructions'),false);assert.equal(p.question,p.oracle.question);assert.equal(p.structuralProvenance.units.map(u=>u.text).join(''),p.question);}
 assert.deepEqual(c.mapping.map(m=>m.variant),['baseline','candidate']);assert.notEqual(c.mapping[0].requestHash,c.mapping[1].requestHash);
 assert.equal(c.mapping[0].planHash,c.mapping[1].planHash);assert.equal(c.mapping[0].oracleHash,c.mapping[1].oracleHash);assert.equal(c.mapping[0].responseHash,c.mapping[1].responseHash);assert.notEqual(c.mapping[0].packetId,c.mapping[1].packetId);assert.notEqual(c.mapping[0].packetHash,c.mapping[1].packetHash);
});
test('same review contents can bind separately to identical plans with distinct packet IDs and hashes',()=>{
 const raw=ledger(),c=create(raw),collection=JSON.stringify(c),review='{}';
 for(const m of c.mapping){const s=resolve(raw,collection,JSON.stringify({packetId:m.packetId,packetHash:m.packetHash,review}));assert.equal(s.job.variant,m.variant);assert.equal(s.job.ordinal,m.ordinal);assert.equal(s.rawReview,review);assert.equal(s.semanticCompleteness,'pending');assert.equal(s.reviewerAuthenticated,false);assert.equal(s.releaseAccepted,false);}
});
test('missing wrong or mixed packet identity is rejected at submission before assigning an arm',()=>{
 const raw=ledger(),c=create(raw),collection=JSON.stringify(c),m=c.mapping[0],n=c.mapping[1];
 for(const s of [{packetId:m.packetId,packetHash:n.packetHash,review:'{}'},{packetId:'other',packetHash:m.packetHash,review:'{}'},{packetHash:m.packetHash,review:'{}'},{packetId:m.packetId,packetHash:m.packetHash,review:'{}',variant:'candidate'},{packetId:m.packetId,packetHash:m.packetHash,review:{}},{packetId:m.packetId,packetHash:m.packetHash,review:'x'.repeat(262145)}])assert.throws(()=>resolve(raw,collection,JSON.stringify(s)),error);
});
test('mapping packet oracle and result alterations fail even if hashes or role names look plausible',()=>{
 const raw=ledger();
 for(const change of [c=>c.mapping[0].variant='candidate',c=>c.mapping[0].ordinal=1,c=>c.mapping[0].requestHash=c.mapping[1].requestHash,c=>c.mapping[0].responseHash='0'.repeat(64),c=>c.mapping[0].planHash='0'.repeat(64),c=>c.mapping[0].oracleHash='0'.repeat(64),c=>c.mapping[1].packetId=c.mapping[0].packetId,c=>c.packets[0].question='private',c=>c.packets[0].oracle.requirements=[],c=>c.packets[0].plan.tasks[0].attribute.label='changed',c=>c.packets[0].variant='baseline',c=>c.mappingHash='0'.repeat(64),c=>c.releaseAccepted=true,c=>c.reviewGateAttached=true]){const c=create(raw);change(c);assert.throws(()=>verify(raw,JSON.stringify(c)),error);}
});
test('different run or completed response binding cannot reuse a collection',()=>{
 const raw=ledger(),collection=JSON.stringify(create(raw));
 for(const kind of ['run','response']){const rows=raw.trimEnd().split('\n').map(JSON.parse);if(kind==='run')rows[0].runId='bb000000-0000-4000-8000-000000000000';else rows[2].result.responseHash='0'.repeat(64);for(let i=1;i<rows.length;i++)rows[i].previous=hash(JSON.stringify(rows[i-1]));assert.throws(()=>verify(encode(rows),collection),error);}
});
test('initial reserved partial and missing stage checkpoint cannot make review packets',()=>{
 const rows=ledger().trimEnd().split('\n').map(JSON.parse);for(const count of [1,2,3,5])assert.throws(()=>create(encode(rows.slice(0,count))),error);
 const stopped=rows.slice(0,2);append(stopped,{type:'failed',ordinal:0,phase:'fetch',httpStatus:429,reason:'upstream_http'});assert.throws(()=>create(encode(stopped)),error);
});
test('bounded JSON fixed diagnostics and strict argument counts do not disclose input',()=>{
 const raw=ledger(),collection=JSON.stringify(create(raw));
 for(const x of [null,{},'private','x'.repeat(2097153)])assert.throws(()=>verify(raw,x),error);
 for(const x of [null,'private','x'.repeat(1048577)])assert.throws(()=>resolve(raw,collection,x),error);
 assert.throws(()=>create(raw,{}),error);assert.throws(()=>verify(raw,collection,{}),error);assert.throws(()=>resolve(raw,collection,'{}',{}),error);
});
test('fresh snapshots isolate caller mutations and packet preparation grants no continuation',()=>{
 const raw=ledger(),c=create(raw),snapshot=JSON.stringify(c),checked=verify(raw,snapshot);checked.mapping[0].variant='other';checked.packets[0].plan.tasks[0].subjects=[];assert.deepEqual(verify(raw,snapshot),c);assert.equal(Object.hasOwn(c,'decision'),false);assert.equal(Object.hasOwn(c,'continue'),false);assert.notEqual(create(raw).mapping[0].packetId,c.mapping[0].packetId);
});
