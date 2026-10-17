import test from 'node:test';
import assert from 'node:assert/strict';
import {guardedTransport,runPilot,validateSelection} from '../scripts/rag-quality/learning-live.mjs';
const apiKey='synthetic-pilot-test-key';
const url='https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:streamGenerateContent?alt=sse';
const options={method:'POST',body:'{}'};
const geminiSuccess=()=>new Response('data: {"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"synthetic answer"}]}}],"usageMetadata":{"promptTokenCount":12,"candidatesTokenCount":3,"totalTokenCount":15},"modelVersion":"gemini-3.5-flash"}\n\n');
const success=()=>new Response('data: {"type":"response.output_text.delta","delta":"synthetic answer"}\n\ndata: {"type":"response.completed","response":{"status":"completed","model":"gpt-6-luna"}}\n\n');

test('pilot compares both styles against the same references and citations',async()=>{
 const result=await runPilot({apiKey,fetchImpl:async()=>success()});
 assert.equal(result.dispatches,6);assert.equal(result.rows.length,6);assert.equal(result.stopped,false);
 for(let i=0;i<6;i+=2){const [a,b]=result.rows.slice(i,i+2);assert.equal(a.inputHash,b.inputHash);assert.equal(a.referenceHash,b.referenceHash);assert.equal(a.configHash,b.configHash);assert.deepEqual(a.citations,b.citations);assert.equal(a.manualReview,'pending');assert.equal(a.checks.requiredFacts,null);assert.equal(a.checks.forbiddenClaims,null);assert.equal(a.semanticAutomatedChecks,'not_configured');assert.ok(a.checks.citationIdentity);}
 assert.ok(!JSON.stringify(result).includes(apiKey));
});
for(const status of [429,500])test(`first ${status} prevents fallback, retries and all later cases`,async()=>{
 let calls=0;
 const result=await runPilot({apiKey,fetchImpl:async()=>{calls++;return new Response('secret='+apiKey,{status});}});
 assert.equal(calls,1);assert.equal(result.dispatches,1);assert.equal(result.rows.length,1);assert.equal(result.stopped,true);assert.equal(result.calls[0].httpStatus,status);
 assert.ok(!JSON.stringify(result).includes(apiKey));assert.ok(!JSON.stringify(result).includes('secret='));
});
test('transport stops at six dispatched calls and before an expired total deadline',async()=>{
 let now=0,dispatches=0;
 const gate=guardedTransport({apiKey,now:()=>now,totalMs:100,fetchImpl:async()=>{dispatches++;return geminiSuccess();}});
 for(let i=0;i<6;i++)await gate.transport(url,options);
 await assert.rejects(gate.transport(url,options));assert.equal(dispatches,6);
 const expired=guardedTransport({apiKey,now:()=>now,totalMs:100,fetchImpl:async()=>{dispatches++;return geminiSuccess();}});
 now=100;await assert.rejects(expired.transport(url,options));assert.equal(dispatches,6);
});
test('slow response body remains within the whole-call deadline',async()=>{
 let signal;
 const gate=guardedTransport({apiKey,timeoutMs:15,fetchImpl:async(_,o)=>{signal=o.signal;return new Response(new ReadableStream({start(c){signal.addEventListener('abort',()=>c.error(Error('aborted')));}}));}});
 await assert.rejects(gate.transport(url,options));assert.equal(signal.aborted,true);assert.equal(gate.isStopped(),true);
});
test('invalid destinations and oversized request never dispatch; redirects are rejected',async()=>{
 for(const value of [NaN,Infinity,0,-1,1.5]){assert.throws(()=>guardedTransport({apiKey,timeoutMs:value}));assert.throws(()=>guardedTransport({apiKey,totalMs:value}));}
 assert.throws(()=>guardedTransport({apiKey,timeoutMs:60001}));assert.throws(()=>guardedTransport({apiKey,totalMs:360001}));
 for(const destination of ['https://evil.invalid/'+apiKey,url+'&key='+apiKey,url.replace('https:','http:'),url.replace('gemini-3.5-flash','gemini-other')]){
  let calls=0;const gate=guardedTransport({apiKey,fetchImpl:async()=>{calls++;return geminiSuccess();}});
  await assert.rejects(gate.transport(destination,options));assert.equal(calls,0);
 }
 let calls=0;const oversized=guardedTransport({apiKey,fetchImpl:async()=>{calls++;return geminiSuccess();}});
 await assert.rejects(oversized.transport(url,{...options,body:'x'.repeat(512*1024+1)}));assert.equal(calls,0);
 const redirect=guardedTransport({apiKey,fetchImpl:async(_,o)=>{assert.equal(o.redirect,'error');assert.equal(o.headers['x-goog-api-key'],apiKey);throw Error('redirect');}});
 await assert.rejects(redirect.transport(url,options));assert.equal(redirect.isStopped(),true);
});
test('oversized, incomplete, malformed, or credential-reflecting success bodies stop evaluation',async()=>{
 for(const body of ['x'.repeat(512*1024+1),'data: {"candidates":[]}\n\n','data: invalid\n\n',`data: {"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"${apiKey}"}]}}]}\n\n`]){
  const gate=guardedTransport({apiKey,fetchImpl:async()=>new Response(body)});
  await assert.rejects(gate.transport(url,options));assert.equal(gate.isStopped(),true);assert.ok(!JSON.stringify(gate.calls).includes(apiKey));
 }
});


test('pending explanations can run first without changing paired snapshots',async()=>{
 const caseIds=['learning-reservation-transfer','learning-circuit'];
 const result=await runPilot({apiKey,caseIds,styleOrder:'explain_first',fetchImpl:async()=>success()});
 assert.equal(result.requested,4);assert.equal(result.dispatches,4);assert.deepEqual(result.caseIds,caseIds);assert.equal(result.styleOrder,'explain_first');
 assert.deepEqual(result.rows.map(r=>[r.id,r.style]),caseIds.flatMap(id=>[[id,'explain'],[id,'source_only']]));
 for(let i=0;i<4;i+=2){const[a,b]=result.rows.slice(i,i+2);assert.equal(a.inputHash,b.inputHash);assert.equal(a.referenceHash,b.referenceHash);assert.equal(a.configHash,b.configHash);assert.deepEqual(a.citations,b.citations);}
});
test('unknown, empty or duplicate pilot selections never dispatch',async()=>{
 for(const caseIds of [[],null,'learning-circuit',[''],['learning-circuit',''],['learning-circuit','learning-circuit'],['unknown'],[3]]){
  let calls=0;await assert.rejects(runPilot({apiKey,caseIds,fetchImpl:async()=>{calls++;return success();}}));assert.equal(calls,0);
 }
 for(const styleOrder of ['',null,'EXPLAIN','unknown'])assert.throws(()=>validateSelection(undefined,styleOrder));
 const fallback=validateSelection();assert.equal(fallback.caseIds.length,3);assert.deepEqual(fallback.styles,['source_only','explain']);
});
test('first explanation 503 stops before its source comparison and later pairs',async()=>{
 let calls=0;const result=await runPilot({apiKey,caseIds:['learning-reservation-transfer','learning-circuit'],styleOrder:'explain_first',fetchImpl:async()=>{calls++;return new Response('private error',{status:503});}});
 assert.equal(calls,1);assert.equal(result.stopped,true);assert.equal(result.requested,4);assert.equal(result.rows.length,1);assert.equal(result.rows[0].style,'explain');assert.equal(result.rows[0].id,'learning-reservation-transfer');assert.equal(result.calls[0].httpStatus,503);
});
