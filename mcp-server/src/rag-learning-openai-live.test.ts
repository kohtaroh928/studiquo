// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import {guardedOpenAITransport,runOpenAIPilot,selectOpenAIProbes,loadOpenAIKey} from '../scripts/rag-quality/learning-openai-live.ts';
const apiKey='synthetic-openai-pilot-key',url='https://api.openai.com/v1/responses';
const options={method:'POST',body:JSON.stringify({model:'gpt-6-luna',instructions:'synthetic',input:[],stream:true,store:false})};
const success=()=>new Response('data: {"type":"response.output_text.delta","delta":"synthetic answer"}\n\ndata: {"type":"response.completed","response":{"status":"completed","model":"gpt-6-luna","usage":{"input_tokens":12,"output_tokens":5,"total_tokens":17,"output_tokens_details":{"reasoning_tokens":2}}}}\n\n');
test('OpenAI paired pilot preserves input reference config and citation identity',async()=>{
 const result=await runOpenAIPilot({apiKey,fetchImpl:async()=>success()});
 assert.equal(result.requested,4);assert.equal(result.dispatches,4);assert.equal(result.stopped,false);
 for(let i=0;i<4;i+=2){const[a,b]=result.rows.slice(i,i+2);assert.equal(a.style,'explain');assert.equal(b.style,'source_only');for(const key of ['inputHash','referenceHash','configHash'])assert.equal(a[key],b[key]);assert.deepEqual(a.citations,b.citations);assert.equal(a.automatedChecksPass,true);assert.equal(a.checks.requiredFacts,null);assert.equal(a.manualReview,'pending');}
 assert.deepEqual(result.calls[0].usage,{input:12,output:5,reasoning:2,total:17});assert.ok(!JSON.stringify(result).includes(apiKey));
});
for(const status of [429,503])test(`OpenAI first ${status} prevents production retry and remaining probes`,async()=>{
 let n=0;const result=await runOpenAIPilot({apiKey,fetchImpl:async()=>{n++;return new Response('private '+apiKey,{status});}});
 assert.equal(n,1);assert.equal(result.dispatches,1);assert.equal(result.stopped,true);assert.equal(result.rows.length,1);assert.equal(result.calls[0].httpStatus,status);assert.ok(!JSON.stringify(result).includes(apiKey));
});
test('OpenAI transport rejects unsafe destinations persistence models and payload size before dispatch',async()=>{
 let n=0;for(const [destination,body] of [[url+'?key=secret',options.body],['https://evil.invalid/v1/responses',options.body],[url,options.body.replace('gpt-6-luna','gpt-other')],[url,options.body.replace('"store":false','"store":true')],[url,'x'.repeat(512*1024+1)]]){
  const gate=guardedOpenAITransport({apiKey,fetchImpl:async()=>{n++;return success();}});await assert.rejects(gate.transport(destination,{...options,body}));
 }assert.equal(n,0);
});
test('OpenAI incomplete missing completion malformed reflected-key and oversized streams are not completed answers',async()=>{
 for(const body of ['data: {"type":"response.output_text.delta","delta":"partial"}\n\n','data: {"type":"response.incomplete","response":{"status":"incomplete"}}\n\n','data: invalid\n\n',`data: {"type":"response.output_text.delta","delta":"${apiKey}"}\n\n`,'x'.repeat(512*1024+1)]){
  const gate=guardedOpenAITransport({apiKey,fetchImpl:async()=>new Response(body)});await assert.rejects(gate.transport(url,options));assert.equal(gate.isStopped(),true);assert.ok(!JSON.stringify(gate.calls).includes(apiKey));
 }
});
test('OpenAI redirect refusal, whole body deadline and six dispatch maximum',async()=>{
 let signal;const slow=guardedOpenAITransport({apiKey,timeoutMs:15,fetchImpl:async(_,o)=>{signal=o.signal;assert.equal(o.redirect,'error');assert.equal(o.headers.authorization,`Bearer ${apiKey}`);return new Response(new ReadableStream({start(c){signal.addEventListener('abort',()=>c.error(Error('abort')));}}));}});
 await assert.rejects(slow.transport(url,options));assert.equal(signal.aborted,true);
 let n=0;const gate=guardedOpenAITransport({apiKey,fetchImpl:async()=>{n++;return success();}});for(let i=0;i<6;i++)await gate.transport(url,options);await assert.rejects(gate.transport(url,options));assert.equal(n,6);
});
test('OpenAI invalid selection and invalid keys fail before network',async()=>{
 for(const ids of [[],null,['unknown'],['learning-circuit','learning-circuit']]){let n=0;await assert.rejects(runOpenAIPilot({apiKey,caseIds:ids,fetchImpl:async()=>{n++;return success();}}));assert.equal(n,0);}
 assert.throws(()=>selectOpenAIProbes(undefined,'other'));assert.throws(()=>loadOpenAIKey({},'/private/tmp/missing-studiquo-key-file'));assert.throws(()=>loadOpenAIKey({OPENAI_API_KEY:'bad key'}));assert.equal(loadOpenAIKey({OPENAI_API_KEY:apiKey}),apiKey);
});

test('new transfer probes stay within six calls and preserve paired evidence',async()=>{
 const caseIds=['learning-print-batch-v4','learning-heat-symbolic-v4','learning-studio-injection-v4'];
 let n=0;const result=await runOpenAIPilot({apiKey,caseIds,fetchImpl:async()=>{n++;return success();}});
 assert.equal(n,6);assert.equal(result.stopped,false);assert.equal(result.rows.length,6);
 for(let i=0;i<6;i+=2){const[a,b]=result.rows.slice(i,i+2);assert.equal(a.automatedChecksPass,true);assert.equal(b.automatedChecksPass,true);for(const key of ['inputHash','referenceHash','configHash'])assert.equal(a[key],b[key]);assert.deepEqual(a.citations,b.citations);}
 let invalidCalls=0;await assert.rejects(runOpenAIPilot({apiKey,caseIds:[...caseIds,'learning-circuit'],fetchImpl:async()=>{invalidCalls++;return success();}}));assert.equal(invalidCalls,0);
});

test('paragraph partial and background probes retain evidence in paired requests',async()=>{
 const caseIds=['learning-transport-paragraphs','learning-partial-devices','learning-density-background'];
 const result=await runOpenAIPilot({apiKey,caseIds,fetchImpl:async()=>success()});
 assert.equal(result.dispatches,6);assert.equal(result.stopped,false);
 for(let i=0;i<6;i+=2){const[a,b]=result.rows.slice(i,i+2);assert.ok(a.automatedChecksPass);assert.ok(b.automatedChecksPass);for(const key of ['inputHash','referenceHash','configHash'])assert.equal(a[key],b[key]);assert.deepEqual(a.citations,b.citations);}
});
