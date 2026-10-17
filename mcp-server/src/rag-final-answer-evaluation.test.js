import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {fixture,holdoutFixture,evaluateCase,sseEvents,checkAnswer,readBounded,loadLocalKey,selectCases} from '../scripts/rag-quality/final-answer-evaluate.mjs';

function responses(text, finishReason='STOP') {
 const events=[{type:'response.output_text.delta',delta:text},finishReason==='STOP'?{type:'response.completed',response:{status:'completed',model:'synthetic-model',usage:{input_tokens:123,output_tokens:45,output_tokens_details:{reasoning_tokens:6},total_tokens:174}}}:{type:'response.incomplete',response:{status:'incomplete'}}];
 return new Response(events.map(e=>`data: ${JSON.stringify(e)}\n\n`).join(''),{headers:{'content-type':'text/event-stream'}});
}

test('24 golden cases exercise exact production request and expected retrieval states with mock OpenAI', async () => {
 assert.equal(fixture.syntheticOnly,true);assert.equal(fixture.cases.length,24);
 for(const c of fixture.cases) {
  let request;
  const hit=await evaluateCase(c,{openaiFetch:async(url,options)=>{
   request=JSON.parse(options.body);
   assert.equal(String(url),'https://api.openai.com/v1/responses');
   assert.equal(request.max_output_tokens,8192);
   return responses('mock回答です。');
  }});
  assert.equal(hit.status,c.expectedStatus??null,c.id);
  assert.deepEqual(hit.citations.map(x=>x.pageNumber).sort((a,b)=>a-b),c.expectedPages,c.id);
  assert.equal(hit.citationDatabaseValid,true,c.id);
  assert.equal(hit.calls[0].promptTokens,123);assert.equal(hit.calls[0].thinkingTokens,6);
  assert.equal(hit.checks.generationComplete,true);assert.equal(hit.manualReview,'pending');
  const prompt=JSON.stringify(request.instructions);
  assert.match(prompt,/Studiquo/);
  if(c.expectedPages.length)assert.match(prompt,/UNTRUSTED/);else assert.doesNotMatch(prompt,/untrustedReferences/);
  if(c.expectedStatus==='grounded'||c.expectedStatus==='partial') {
   assert.match(prompt,/無理に定義せず/);
   assert.match(prompt,/未記載の用途/);
   assert.match(prompt,/独立した事実記述まで捨てない/);
   assert.match(prompt,/引用表記として回答本文へ出力しない/);
   assert.match(prompt,/出典を捏造してはいけません/);
  }
  if(c.expectedStatus==='insufficient')assert.match(prompt,/requested information in the retrieved excerpts/);
  if(c.expectedStatus==='insufficient') {
   assert.match(prompt,/似た名前の既知の物や用語と同一視せず/);
   assert.match(prompt,/別の対象の価格・数値・配列・数式/);
   assert.match(prompt,/Do not continue with a general knowledge answer/);
   assert.match(prompt,/一般知識による代替回答も続けない/);
   assert.doesNotMatch(prompt,/If continuing with general knowledge/);
  }
  if(['fallback','ordinary'].includes(c.category))assert.doesNotMatch(prompt,/資料検索を使う回答では|似た名前の既知の物や用語と同一視せず/);
  if(c.expectedStatus==='partial')assert.match(prompt,/full comparison cannot be grounded/);
 }
});

test('generation incomplete or absent STOP cannot count as a completed quality result', async () => {
 for(const reason of ['MAX_TOKENS','SAFETY',undefined]) {
  const hit=await evaluateCase(fixture.cases[0],{openaiFetch:async()=>responses('紫色',reason===undefined?'FINISH_REASON_UNSPECIFIED':reason)});
  assert.equal(hit.checks.generationComplete,false);assert.equal(hit.automatedChecksPass,false);
 }
});

test('no-answer and non-200 upstream are execution failures, not correct answers', async () => {
 const empty=await evaluateCase(fixture.cases[0],{openaiFetch:async()=>responses('')});
 assert.equal(empty.checks.transport,false);
 const failed=await evaluateCase(fixture.cases[0],{openaiFetch:async()=>new Response('private-provider-details',{status:400})});
 assert.equal(failed.checks.transport,false);assert.equal(failed.httpStatus,400);
 assert.equal(failed.answer,'');assert.ok(!JSON.stringify(failed).includes('private-provider-details'));
});

test('upstream exception containing credential or prompt details never reaches logs or artifacts', async () => {
 const originalLog=console.log;const originalError=console.error;const originalWarn=console.warn;const output=[];
 const remember=(...args)=>output.push(args.map(String).join(' '));console.log=remember;console.error=remember;console.warn=remember;
 try {
  const hit=await evaluateCase(fixture.cases[0],{openaiFetch:async()=>{throw new Error('synthetic-secret-and-private-prompt');}});
  assert.equal(hit.checks.transport,false);
  assert.ok(!JSON.stringify(hit).includes('synthetic-secret-and-private-prompt'));
  assert.ok(!output.join('\n').includes('synthetic-secret-and-private-prompt'));
 } finally {console.log=originalLog;console.error=originalError;console.warn=originalWarn;}
});

test('SSE parsing preserves multiple chunks, CRLF, usage-only and unknown events', () => {
 const events=sseEvents('data: {"text":"a"}\r\n\r\ndata: {"usageMetadata":{}}\n\ndata: {"unknown":1}\n\ndata: [DONE]\n\n');
 assert.equal(events.length,3);assert.equal(events[0].text,'a');assert.deepEqual(events[1].usageMetadata,{});
 assert.throws(()=>sseEvents('data: invalid\n\n'),/invalid_sse_event/);
});

test('oversized SSE is bounded and transport replacement is restored', async () => {
 await assert.rejects(readBounded(new Response('x'.repeat(100)),10),/response_size_exceeded/);
 const original=globalThis.fetch;
 const hit=await evaluateCase(fixture.cases[0],{openaiFetch:async()=>new Response('x'.repeat(600000))});
 assert.equal(hit.checks.transport,false);assert.equal(globalThis.fetch,original);
});

test('keyword checks do not claim semantic correctness; manual review stays pending', () => {
 const c=fixture.cases[1];
 const hit={httpStatus:200,answer:'17度ではありません。',status:'grounded',citationDatabaseValid:true,citations:[{sourceId:`answer-${c.id}`,title:'合成教材 最終回答評価',pageNumber:1,chunkId:'synthetic-chunk'}],calls:[{httpStatus:200,finishReasons:['STOP']}]};
 const review=checkAnswer(c,hit);
 assert.equal(review.automatedChecksPass,true);assert.equal(review.manualReview,'pending');
 assert.ok(review.manualChecks.length>0);
});

test('local credential loading has no import side effects and uses explicit env or ignored file', () => {
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'rag-answer-credential-test-'));const file=path.join(dir,'.dev.vars');
 try {
  assert.equal(loadLocalKey({OPENAI_API_KEY:'synthetic-key'},file),'synthetic-key');
  assert.throws(()=>loadLocalKey({},file),/openai_key_not_configured/);
  fs.writeFileSync(file,'OPENAI_API_KEY="synthetic-key"\n');assert.equal(loadLocalKey({},file),'synthetic-key');
  fs.writeFileSync(file,'OPENAI_API_KEY="bad key"\n');assert.throws(()=>loadLocalKey({},file),/openai_key_invalid/);
 } finally {fs.rmSync(dir,{recursive:true});}
});

test('repeat evaluation selects only fixed synthetic case IDs and deduplicates them', () => {
 assert.equal(selectCases().length,24);
 assert.deepEqual(selectCases('injection-role,insufficient-price,injection-role').map(c=>c.id),['insufficient-price','injection-role']);
 assert.throws(()=>selectCases('private-new-question'),/unknown_evaluation_case/);
 assert.throws(()=>selectCases('injection-role,'),/unknown_evaluation_case/);
});


test('fixed holdout retains retrieval and structured citation correctness with new names and values', async () => {
 assert.equal(holdoutFixture.syntheticOnly,true);
 assert.equal(selectCases(undefined,holdoutFixture).length,7);
 assert.throws(()=>selectCases('grounded-multipage',holdoutFixture),/unknown_evaluation_case/);
 assert.throws(()=>selectCases(undefined,{cases:[]}),/unknown_evaluation_fixture/);
 for(const c of holdoutFixture.cases) {
  const result=await evaluateCase(c,{openaiFetch:async()=>responses('合成回答')});
  assert.equal(result.status,c.expectedStatus,c.id);
  assert.deepEqual(result.citations.map(x=>x.pageNumber).sort((a,b)=>a-b),c.expectedPages,c.id);
  assert.equal(result.citationDatabaseValid,true,c.id);
 }
});

test('holdout answer checks accept new model and price and reject baseline values', () => {
 const c=holdoutFixture.cases.find(x=>x.id==='holdout-grounded-multipage');
 const base={httpStatus:200,status:c.expectedStatus,citationDatabaseValid:true,citations:c.expectedPages.map(pageNumber=>({sourceId:`answer-${c.id}`,title:'合成教材 最終回答評価',pageNumber,chunkId:'synthetic-chunk'})),calls:[{httpStatus:200,finishReasons:['STOP']}]};
 assert.equal(checkAnswer(c,{...base,answer:'ノエ計の型番はNE-613、価格は9300円です。'}).automatedChecksPass,true);
 assert.equal(checkAnswer(c,{...base,answer:'型番はLM-204、価格は7200円です。'}).checks.requiredFacts,false);
});

test('zero relevant hits preserve the exact ordinary OpenAI request', async () => {
 const c=holdoutFixture.cases.find(x=>x.id==='holdout-no-hits');
 const requests=[];
 const transport=async(_url,options)=>{requests.push(JSON.parse(options.body));return responses('180度です。');};
 const zero=await evaluateCase(c,{openaiFetch:transport});
 const ordinary=await evaluateCase({...c,mode:'disabled'},{openaiFetch:transport});
 assert.equal(zero.status,'fallback');assert.equal(ordinary.status,null);
 assert.deepEqual(requests[0],requests[1]);
 assert.deepEqual(zero.citations,[]);
});
