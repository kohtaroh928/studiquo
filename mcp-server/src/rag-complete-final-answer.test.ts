// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {loadResumeFixture,newResumeState} from '../scripts/rag-quality/paragraph-resume.ts';
import {selectedAnswerContexts,finalAnswerChecks,answerBody,evaluateSelectedAnswers} from '../scripts/rag-quality/complete-final-answer.ts';
const f=await loadResumeFixture('multiparagraph-complete');
const a=JSON.parse(await readFile(new URL('../../docs/RAG_COMPLETE_WITNESS_FIX_RESULTS.json',import.meta.url)));
const b=JSON.parse(await readFile(new URL('../../docs/RAG_COMPLETE_WITNESS_RECHECK_RESULTS.json',import.meta.url)));
const reports=[{fixtureIdentity:a.fixtureIdentity,report:a.currentRun.report},{fixtureIdentity:b.fixtureIdentity,report:b.recheck.report}];
const state=()=>{const s=newResumeState(f,{witnessPolicy:'complete'});s.cases=reports.flatMap(x=>x.report.cases).filter(x=>x.status==='shadow').map(x=>({id:x.id,status:'shadow',referenceIds:x.shadow.referenceIds,completedAtUTC:new Date(0).toISOString()}));return s;};
const contexts=()=>selectedAnswerContexts(f,state(),reports).contexts;
const formula='v = v_0 + a t。v_0 は初速度、t は経過時間です。速度は m/s、加速度は m/s^2、時間は s。加速度が一定の場合に使います。加速度が変わる場合は適用できない。';
const exception='月額100円は法人のみです。個人は対象外です。紙の資料を発送する場合は送料が別途かかります。具体的な送料は資料に記載がないため不明です。';
const response=text=>Response.json({modelVersion:'gemini-3.6-flash',candidates:[{finishReason:'STOP',content:{parts:[{text}]}}]});
test('full canonical references and correct citation pages are reconstructed',()=>{
 const cs=contexts();assert.deepEqual(cs[0].citations.map(c=>c.pageNumber),[7,8]);assert.deepEqual(cs[1].citations.map(c=>c.pageNumber),[10,2]);
 for(const x of cs)for(const r of x.refs)assert.equal(r.text,x.c.references.find(z=>z.id===r.id).text);
 assert.ok(cs.every(x=>x.citations.every(c=>c.chunkId.startsWith('evaluation-'))));
});
test('future quota gate and stale policy fail before remote work',()=>{
 const s=state();s.notBeforeUTC=new Date(Date.now()+60000).toISOString();assert.equal(selectedAnswerContexts(f,s,reports).blocked,true);assert.throws(()=>selectedAnswerContexts(f,newResumeState(f),reports),/stale/);
});
test('wrong model or policy fails closed',()=>{
 for(const field of ['model','witnessPolicy']){const r=structuredClone(reports);r[0].report[field]='wrong';assert.throws(()=>selectedAnswerContexts(f,state(),r),/invalid_selection_report/);}
});
test('foreign references, foreign witnesses and missing units fail closed',()=>{
 for(const mutate of [r=>r.shadow.referenceIds.push('foreign'),r=>r.witnessCoverage.witnessIds.push('foreign'),r=>{r.witnessCoverage.witnessIds=r.witnessCoverage.witnessIds.filter(x=>x!=='r1_p4');}]){
 const rr=structuredClone(reports);mutate(rr[0].report.cases.find(c=>c.id==='multi-formula-domain'));assert.throws(()=>selectedAnswerContexts(f,state(),rr));
 }
});
test('gold labels are excluded and full text is marked untrusted',()=>{
 const x=contexts()[0];x.c={...x.c,facts:[{secretGold:'GOLD_DO_NOT_SEND'}]};const body=JSON.stringify(answerBody(x));assert.ok(!body.includes('GOLD_DO_NOT_SEND'));assert.ok(body.includes('UNTRUSTED'));assert.ok(body.includes('m/s'));assert.ok(!body.includes('responseJsonSchema'));
});
test('Japanese and LaTex answers pass preliminary formula checks',()=>{
 assert.ok(Object.values(finalAnswerChecks('multi-formula-domain',formula)).every(Boolean));assert.ok(Object.values(finalAnswerChecks('multi-formula-domain',formula.replace('m/s^2','\\mathrm{m}/\\mathrm{s}^{2}'))).every(Boolean));
});
test('missing units and reversed exception fail separate signals',()=>{
 assert.equal(finalAnswerChecks('multi-formula-domain',formula.replace('m/s^2','単位省略')).accelerationUnit,false);assert.equal(finalAnswerChecks('multi-formula-domain',formula.replace('適用できない','適用できます')).exception,false);
});
test('price exclusion and unknown shipping checks reject reversed exclusion and invented fee',()=>{
 assert.ok(Object.values(finalAnswerChecks('multi-cross-source-exception',exception)).every(Boolean));assert.equal(finalAnswerChecks('multi-cross-source-exception',exception.replace('個人は対象外','個人も対象')).individualExcluded,false);assert.equal(finalAnswerChecks('multi-cross-source-exception',exception+'送料は500円です。').noInventedShippingAmount,false);
});
test('two requests are serial and raw answers stay outside metrics',async()=>{
 let calls=0;const waits=[];const out=await evaluateSelectedAnswers(contexts(),{apiKey:'test-credential',wait:async ms=>waits.push(ms),fetchImpl:async()=>response(calls++===0?formula:exception)});assert.equal(calls,2);assert.deepEqual(waits,[31000]);assert.equal(out.answers.length,2);assert.equal(out.rows[0].manualReview,'pending');assert.ok(!JSON.stringify(out.rows).includes('初速度'));assert.ok(out.rows.every(r=>Object.values(r.checks).every(Boolean)));
});
for(const status of [401,403,429,503])test(`HTTP ${status} stops without retry or error-text leakage`,async()=>{
 let calls=0;const out=await evaluateSelectedAnswers(contexts(),{apiKey:'test-credential',fetchImpl:async()=>{calls++;return Response.json({error:{status:'UNAVAILABLE',message:'PRIVATE_ERROR'}},{status});},wait:async()=>assert.fail('unexpected wait')});assert.equal(calls,1);assert.equal(out.answers.length,0);assert.equal(out.rows[0].checks,null);assert.ok(!JSON.stringify(out).includes('PRIVATE_ERROR'));
});
test('credential echoed by model is never archived',async()=>{
 const out=await evaluateSelectedAnswers(contexts(),{apiKey:'test-credential',fetchImpl:async()=>response('test-credential'),wait:async()=>{}});assert.equal(out.answers.length,0);assert.ok(!JSON.stringify(out).includes('test-credential'));
});
test('timeout is not a completed answer or quality result',async()=>{
 const out=await evaluateSelectedAnswers(contexts(),{apiKey:'test-credential',timeoutMs:10,fetchImpl:async()=>new Response(new ReadableStream({start(){}})),wait:async()=>{}});assert.ok(out.rows.every(r=>r.outcome==='timeout'&&r.checks===null));assert.equal(out.answers.length,0);
});

test('stale report identity and selection state mismatch are rejected',()=>{const rr=structuredClone(reports);rr[1].fixtureIdentity='stale';assert.throws(()=>selectedAnswerContexts(f,state(),rr),/stale_selection_report/);const s=state();s.cases.find(x=>x.id==='multi-formula-domain').referenceIds=['r1'];assert.throws(()=>selectedAnswerContexts(f,s,reports),/selection_state_mismatch/);});
test('shipping amount behind extra modifiers is rejected',()=>{assert.equal(finalAnswerChecks('multi-cross-source-exception',exception+'送料は別途300円です。').noInventedShippingAmount,false);});

test('passive unspecified concrete fee wording is recognized without accepting numeric invention',()=>{const x=exception.replace('具体的な送料は資料に記載がないため不明です','具体額は配送地域によって異なり、資料内では定められていません');assert.equal(finalAnswerChecks('multi-cross-source-exception',x).amountUnknown,true);assert.equal(finalAnswerChecks('multi-cross-source-exception',x+'送料は別途300円').noInventedShippingAmount,false);});
