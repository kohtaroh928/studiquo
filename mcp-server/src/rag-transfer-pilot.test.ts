import test from 'node:test';
import assert from 'node:assert/strict';
import {transferFixture as fixture} from '../scripts/rag-quality/transfer-fixture.ts';
import {paragraphTask} from '../scripts/rag-quality/paragraph-proposal.ts';
import {measureWitnesses,evaluateWitnessControls} from '../scripts/rag-quality/paragraph-witness-evaluate.ts';
import {newResumeState,loadResumeFixture,resumeWitnessPolicy} from '../scripts/rag-quality/paragraph-resume.ts';
import {transferContexts,transferAnswerIdentity,runTransferAnswers} from '../scripts/rag-quality/transfer-final-answer.ts';
import {answerBody} from '../scripts/rag-quality/complete-final-answer.ts';
function prepared(){
 const state=newResumeState(fixture,{witnessPolicy:'complete'}),cases=fixture.cases.map(c=>{
  const task=paragraphTask(c.question,c.references),witnesses=task.paragraphs.filter(p=>c.facts.some(f=>f.evidence.some(e=>e.referenceId===p.referenceId&&p.start<e.end&&e.start<p.end)));
  state.cases.push({id:c.id,status:'shadow',referenceIds:task.references.map(r=>r.id),completedAtUTC:new Date(0).toISOString()});
  return {id:c.id,status:'shadow',requiredCoverageStatus:'complete',shadow:{referenceIds:task.references.map(r=>r.id)},witnessCoverage:measureWitnesses(c,task,task.references,witnesses)};
 });
 return {state,selection:{fixtureIdentity:state.identity,report:{model:'gemini-3.6-flash',witnessPolicy:'complete',cases}}};
}
const reply=text=>Response.json({modelVersion:'gemini-3.6-flash',candidates:[{finishReason:'STOP',content:{parts:[{text}]}}]});
test('frozen new fixture has nine canonical facts within three-slot budget',()=>{
 assert.equal(fixture.cases.flatMap(c=>c.facts).length,9);assert.ok(Object.isFrozen(fixture.cases[0].references));const controls=evaluateWitnessControls(fixture);assert.equal(controls.summary.labelOracleMissingCases,0);assert.equal(controls.summary.firstParagraphMissingCases,2);
 for(const c of controls.cases)for(const r of fixture.cases.find(x=>x.id===c.id).references)assert.ok(c.labelOracle.witnessIds.filter(id=>id.startsWith(r.id+'_')).length<=3);
 assert.match(fixture.labelStatus,/not independent blind/);assert.match(fixture.labelStatus,/simulated/);
});
test('transfer profile is complete and old identity remains unchanged',async()=>{
 assert.equal(await loadResumeFixture('transfer-complete'),fixture);assert.equal(resumeWitnessPolicy('transfer-complete'),'complete');assert.equal(resumeWitnessPolicy(),'baseline');assert.equal(newResumeState(await loadResumeFixture()).identity,'64065b142e48cca4b4295ba6359e74d5339a38296fb8e1625cf79f669a5a0f58');
});
test('full context and canonical pages preserve suspicious text as untrusted data, never labels',()=>{
 const {state,selection}=prepared(),out=transferContexts(state,selection);assert.equal(out.status,'ready');assert.deepEqual(out.contexts.map(x=>x.citations.map(c=>c.pageNumber)),[[12,3],[21,4]]);const body=answerBody(out.contexts[1]);assert.ok(body.systemInstruction.parts[0].text.includes('UNTRUSTED'));assert.ok(body.systemInstruction.parts[0].text.includes('99 N'));assert.equal(body.contents[0].parts[0].text,fixture.cases[1].question);assert.ok(!JSON.stringify(body).includes('uncertain-exponent'));assert.equal(out.contexts[1].refs[0].text,fixture.cases[1].references[0].text);
});
test('answer identity binds full body and actual deadline',()=>{
 const {state,selection}=prepared(),cs=transferContexts(state,selection).contexts,h=transferAnswerIdentity(cs),m=structuredClone(cs);m[0].refs[0].text+='changed';assert.notEqual(transferAnswerIdentity(m),h);assert.notEqual(transferAnswerIdentity(cs,{timeoutMs:10000}),h);
});
test('quota wait avoids key and network access',async()=>{
 const {state,selection}=prepared();state.notBeforeUTC=new Date(2000).toISOString();const out=await runTransferAnswers(state,selection,{now:()=>1000,loadKey:async()=>assert.fail('key'),fetchImpl:async()=>assert.fail('network')});assert.equal(out.status,'quota_wait');assert.equal(out.externalCalls,0);
});
test('fallback selection blocks final answers without becoming quality result',async()=>{
 const {state,selection}=prepared();selection.report.cases[0].status='fallback';const out=await runTransferAnswers(state,selection,{loadKey:async()=>assert.fail('key read')});assert.equal(out.status,'selection_incomplete');assert.equal(out.externalCalls,0);
});
test('stale identity, ID mismatch or incomplete witnesses reject before credential access',async()=>{
 for(const mutate of [(s,r)=>{r.fixtureIdentity='wrong';},(s,r)=>{r.report.cases[0].shadow.referenceIds=['r1'];},(s,r)=>{r.report.cases[0].witnessCoverage.witnessIds=['r1_p2'];}]){const {state,selection}=prepared();mutate(state,selection);await assert.rejects(runTransferAnswers(state,selection,{loadKey:async()=>assert.fail('key read')}));}
});
test('format completion is ungraded; requests paced and raw text separated',async()=>{
 const {state,selection}=prepared();let calls=0;const waits=[],out=await runTransferAnswers(state,selection,{loadKey:async()=>'test-key',fetchImpl:async()=>{calls++;return reply('SYNTHETIC_WRONG_ANSWER');},wait:async ms=>waits.push(ms)});assert.equal(calls,2);assert.deepEqual(waits,[31000]);assert.equal(out.answers.length,2);assert.ok(out.rows.every(r=>r.answerAvailable&&r.qualityStatus==='not_evaluated'&&r.manualReview==='pending'));assert.ok(!JSON.stringify(out.rows).includes('SYNTHETIC_WRONG_ANSWER'));
});
for(const status of [401,403,429,503])test(`HTTP${status} stops and hides provider message`,async()=>{
 const {state,selection}=prepared();let calls=0;const out=await runTransferAnswers(state,selection,{loadKey:async()=>'test-key',fetchImpl:async()=>{calls++;return Response.json({error:{status:'UNAVAILABLE',message:'PRIVATE_FAILURE'}},{status});},wait:async()=>assert.fail('wait')});assert.equal(calls,1);assert.equal(out.answers.length,0);assert.ok(!JSON.stringify(out).includes('PRIVATE_FAILURE'));
});
test('echoed credentials are never archived',async()=>{
 const {state,selection}=prepared();const out=await runTransferAnswers(state,selection,{loadKey:async()=>'test-key',fetchImpl:async()=>reply('test-key'),wait:async()=>{}});assert.equal(out.answers.length,0);assert.ok(!JSON.stringify(out).includes('test-key'));
});
test('timeout does not become an answer and measured identity uses actual limit',async()=>{
 const {state,selection}=prepared();const cs=transferContexts(state,selection).contexts;let identity;const out=await runTransferAnswers(state,selection,{loadKey:async()=>'test-key',timeoutMs:5,fetchImpl:async()=>new Response(new ReadableStream({start(){}})),wait:async()=>{},onRow:async x=>{identity=x.answerIdentity;}});assert.ok(out.rows.every(r=>r.outcome==='timeout'&&!r.answerAvailable));assert.equal(out.answers.length,0);assert.equal(identity,transferAnswerIdentity(cs,{timeoutMs:5}));
});
