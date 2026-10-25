// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {geminiProposer,PROPOSAL_MODEL} from '../scripts/rag-quality/selection-proposal-gemini.ts';
import {evaluateLive} from '../scripts/rag-quality/selection-proposal-live.ts';
import {proposalTask,proposalMessages,runProposal} from '../scripts/rag-quality/selection-proposal.ts';
const fixture=JSON.parse(await readFile(new URL('../scripts/rag-quality/citation-intent-fixture.json',import.meta.url)));
const task=()=>proposalTask('合成質問',[{id:'r1',sourceId:'synthetic',pageNumber:1,title:'合成',text:'合成資料の内容。'}]);
const packet=(raw,extra={})=>JSON.stringify({candidates:[{finishReason:'STOP',content:{parts:[{text:raw}]}}],modelVersion:PROPOSAL_MODEL,usageMetadata:{promptTokenCount:10,candidatesTokenCount:5,thoughtsTokenCount:2,totalTokenCount:17},...extra});
const proposal=t=>JSON.stringify({version:1,snapshot:t.snapshot,decision:'select',decisions:t.references.map(r=>({referenceId:r.id,action:'retain',reason:'answer',spans:[{start:0,end:r.text.length,quote:r.text}]}))});
test('transport uses fixed endpoint, header key, schema and AbortSignal',async()=>{
 const t=task();let metrics;const raw=await geminiProposer({apiKey:'synthetic-key',observe:m=>metrics=m,fetchImpl:async(url,options)=>{
  assert.ok(!url.includes('synthetic-key'));assert.match(url,/^https:\/\/generativelanguage\.googleapis\.com\//);assert.equal(options.redirect,'error');assert.equal(options.headers['x-goog-api-key'],'synthetic-key');assert.ok(options.signal);
  const body=JSON.parse(options.body);assert.equal(body.generationConfig.maxOutputTokens,4096);assert.equal(body.generationConfig.temperature,1);assert.equal(body.generationConfig.thinkingConfig.thinkingLevel,'minimal');assert.equal(body.generationConfig.responseMimeType,'application/json');assert.ok(body.generationConfig.responseJsonSchema);
  return new Response(packet(proposal(t)));
 }})(proposalMessages(t),{signal:new AbortController().signal});
 assert.equal(raw,proposal(t));assert.deepEqual(metrics.usage,{prompt:10,output:5,thoughts:2,total:17,cached:null});assert.ok(!JSON.stringify(metrics).includes('synthetic-key'));
});
for(const [name,response]of[
 ['HTTP error',()=>new Response('SENSITIVE ERROR',{status:403})],
 ['oversize body',()=>new Response('x'.repeat(65537))],
 ['invalid JSON',()=>new Response('{')],
 ['model refusal',()=>new Response(packet('',{candidates:[{finishReason:'SAFETY'}]}))],
 ['truncated output',()=>new Response(packet('{}',{candidates:[{finishReason:'MAX_TOKENS'}]}))],
 ['missing output',()=>new Response(packet(''))],
 ['oversize model text',()=>new Response(packet('x'.repeat(32769)))],
 ])test(`provider ${name} restores baseline without error body`,async()=>{
 const t=task(),out=await runProposal(t,geminiProposer({apiKey:'synthetic',fetchImpl:async()=>response()}));assert.equal(out.status,'fallback');assert.deepEqual(out.safeReferences,t.references);assert.ok(!JSON.stringify(out).includes('SENSITIVE'));
});
test('transport abort also covers a stalled response body',async()=>{
 const t=task();let cancelled=false;
 const out=await runProposal(t,geminiProposer({apiKey:'synthetic',fetchImpl:async(_url,{signal})=>new Response(new ReadableStream({start(controller){signal.addEventListener('abort',()=>controller.error(Error('aborted')));},cancel(){cancelled=true;}}))}),{timeoutMs:10});
 assert.equal(out.reason,'timeout');assert.equal(out.productionEligible,false);
});
test('whole fixture replays with no labels, bounded call count and safe metrics',async()=>{
 let calls=0;const report=await evaluateLive(fixture,{apiKey:'synthetic',fetchImpl:async(_url,options)=>{
  calls++;const body=JSON.parse(options.body),data=JSON.parse(body.contents[0].parts[0].text);
  assert.ok(!Object.hasOwn(data,'facts'));assert.ok(data.references.every(r=>!Object.hasOwn(r,'facts')));
  const raw=JSON.stringify({version:1,snapshot:data.snapshot,decision:'select',decisions:data.references.map(r=>({referenceId:r.id,action:'retain',reason:'answer',spans:[{start:0,end:Math.min(20,r.text.length),quote:r.text.slice(0,20)}]}))});return new Response(packet(raw));
 }});
 assert.equal(calls,16);assert.equal(report.summary.validProposals,16);assert.equal(report.summary.validButMissingRequired,0);assert.equal(report.summary.estimatedCostUSD,null);assert.equal(report.summary.usageTotals.total,272);assert.equal(report.summary.usageTotals.output,80);assert.ok(report.cases.every(c=>!c.productionEligible));
});
test('preflight rejects over budget or invalid fixture before any request',async()=>{
 let calls=0;const options={apiKey:'synthetic',fetchImpl:()=>{calls++;throw Error();}};
 const many=structuredClone(fixture);many.cases=Array.from({length:21},(_,i)=>({...structuredClone(fixture.cases[0]),id:'case'+i}));await assert.rejects(evaluateLive(many,options),/call_budget/);
 const bad=structuredClone(fixture);bad.cases.at(-1).question='x'.repeat(2001);await assert.rejects(evaluateLive(bad,options),/invalid_task/);assert.equal(calls,0);
});

for(const code of [401,403,429,503])test(`HTTP ${code} stops further paid requests`,async()=>{
 let calls=0;const report=await evaluateLive(fixture,{apiKey:'synthetic',fetchImpl:async()=>{calls++;return new Response('PRIVATE ERROR',{status:code});}});
 assert.equal(calls,1);assert.equal(report.summary.plannedCases,16);assert.equal(report.summary.attempts,1);assert.equal(report.summary.notAttempted,15);assert.equal(report.summary.stoppedEarly,true);
 assert.equal(report.summary.usageObservedCalls,0);assert.equal(report.summary.estimatedCostUSD,null);assert.ok(!JSON.stringify(report).includes('PRIVATE ERROR'));
});

test('HTTP429 remains observable when error body cancellation stalls',async()=>{
 const t=task();let metrics=null;
 const out=await runProposal(t,geminiProposer({apiKey:'synthetic',observe:m=>metrics=m,fetchImpl:async()=>new Response(new ReadableStream({cancel(){return new Promise(()=>{});}}),{status:429})}),{timeoutMs:10});
 assert.equal(out.reason,'timeout');assert.equal(metrics.httpStatus,429);assert.equal(out.productionEligible,false);
});
