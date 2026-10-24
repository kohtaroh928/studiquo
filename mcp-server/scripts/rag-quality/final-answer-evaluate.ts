// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
// Evaluation tooling only: synthetic fixture, production handleAI, local retrieval.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { performance } from 'node:perf_hooks';
import { handleAI } from '../../src/ai.ts';
import { indexSource, accountKey } from '../../src/rag/storage.ts';
import { qualityEnvironment, qualitySource } from '../../src/rag-quality-fixture.ts';

export const fixture = JSON.parse(fs.readFileSync(new URL('./final-answer-fixture.json', import.meta.url), 'utf8') as any);

export const holdoutFixture = JSON.parse(fs.readFileSync(new URL('./final-answer-holdout.json', import.meta.url), 'utf8') as any);

export async function readBounded(response: any, limit = 512 * 1024) {
 if (!response.body) return '';
 const reader = response.body.getReader();
 const decoder = new TextDecoder();let size=0;let text='';
 try {
  for (;;) {
   const {done,value}=await reader.read();if(done)break;
   size+=value.byteLength;
   if(size>limit){await reader.cancel();throw new Error('response_size_exceeded');}
   text+=decoder.decode(value,{stream:true});
  }
  return text+decoder.decode();
 } finally {reader.releaseLock();}
}

export function sseEvents(text: any) {
 const events=[];
 for(const block of String(text).replace(/\r\n/gu,'\n').split('\n\n')) {
  const data=block.split('\n').filter(line=>line.startsWith('data:')).map(line=>line.slice(5).trimStart()).join('\n');
  if(!data || data==='[DONE]')continue;
  try {events.push(JSON.parse(data));} catch {throw new Error('invalid_sse_event');}
 }
 return events;
}

export function checkAnswer(testCase: any, result: any) {
 const expected=[...testCase.expectedPages].sort((a,b)=>a-b);
 const actual=result.citations.map((c: any)=>c.pageNumber).sort((a: any,b: any)=>a-b);
 const checks={
  transport:result.httpStatus===200 && result.answer.trim().length>0,
  generationComplete:result.calls.filter((c: any)=>c.httpStatus===200).at(-1)?.finishReasons?.length>0 && result.calls.filter((c: any)=>c.httpStatus===200).at(-1).finishReasons.every((reason: any)=>reason==='STOP'),
  retrievalStatus:result.status===(testCase.expectedStatus??null),
  citationPages:JSON.stringify(actual)===JSON.stringify(expected),
  citationIdentity:result.citationDatabaseValid && result.citations.every((c: any)=>c.sourceId===`answer-${testCase.id}` && c.title==='合成教材 最終回答評価' && typeof c.chunkId==='string' && c.chunkId.length>0),
  requiredFacts:(testCase.requiredPatterns??[]).every((pattern: any)=>new RegExp(pattern,'iu').test(result.answer.normalize('NFKC'))),
  forbiddenClaims:(testCase.forbiddenPatterns??[]).every((pattern: any)=>!new RegExp(pattern,'iu').test(result.answer)),
 };
 // These are preliminary signals, not a factual/grounding pass verdict.
 return {checks,automatedChecksPass:Object.values(checks).every(Boolean),manualReview:'pending',manualChecks:testCase.manualChecks};
}

export async function evaluateCase(testCase: any, {apiKey, openaiFetch, model}: any = {}) {
 if(typeof openaiFetch!=='function')throw new Error('openai_transport_required');
 const env=qualityEnvironment();const values=new Map();
 Object.assign(env,{
  OPENAI_API_KEY:apiKey??'synthetic-test-key',
  STUDIQUO_DATA:{get:async(k: any,type: any)=>{const v=values.get(k);return type==='json'&&v?JSON.parse(v):v??null;},put:async(k: any,v: any)=>{values.set(k,v);}},
  RATE_COUNTER:{getByName:()=>({bump:async()=>true,take:async()=>({ok:true,windowEndsAt:1}),give:async()=>{}, reserve: async () => ({ ok: true, windowEndsAt: 1 }), release: async () => true})},
 });
 env.OPENAI_LUNA_MODEL=model??'gpt-6-luna';env.AI_MODERATION='off';env.AI_RETRY_BASE_MS=0;
 const sourceId=`answer-${testCase.id}`;
 const keyForCitations=await accountKey('synthetic-answer-owner');
 const pages=testCase.pages.map((text: any,i: any)=>({pageNumber:i+1,text}));
 await indexSource(env,keyForCitations,qualitySource({sourceId,title:'合成教材 最終回答評価',totalPages:pages.length,pages}));
 if(testCase.mode==='no_hits')env.RAG_VECTORIZE.query=async()=>({matches:[]});
 if(testCase.mode==='outage')env.AI.run=async()=>{throw new Error('synthetic_retrieval_outage');};
 if(testCase.mode==='rate_limit')env.RATE_LIMIT_RAG_SEARCH.limit=async()=>({success:false});
 if(testCase.mode==='disabled')env.RAG_ENABLED='false';
 const messages=testCase.previousQuestion?[{role:'user',text:testCase.previousQuestion},{role:'assistant',text:'この説明について続けて質問できます。'},{role:'user',text:testCase.query}]:[{role:'user',text:testCase.query}];
 const request=new Request('https://example.test/api/ai/chat',{method:'POST',headers:{'content-type':'application/json','X-Studiquo-AI-Consent':'openai-v1','X-Studiquo-Age':'adult',...(testCase.mode==='no_consent'?{}:{'X-Studiquo-RAG-Consent':'rag-openai-v1'})},body:JSON.stringify({messages,rag:{scope:{kind:'notebook',sourceId},...(testCase.answerStyle===undefined?{}:{answerStyle:testCase.answerStyle})}})});
 const pending: any[]=[];const original=globalThis.fetch;const calls: any[]=[];const start=performance.now();
 globalThis.fetch=async(url,options)=>{
  try {
  const parsed=new URL(url);
  if(parsed.href!=='https://api.openai.com/v1/responses')throw new Error('unexpected_upstream');
  const callStart=performance.now();const response=await openaiFetch(url,options);
  const body=await readBounded(response);
  const events=response.ok?sseEvents(body):[];
  const completion=events.find(e=>e.type==='response.completed')?.response;
  const usage=completion?.usage??null;
  const hasOutput=events.some(e=>e.type==='response.output_text.delta'&&typeof e.delta==='string'&&e.delta.trim());
  const complete=hasOutput&&completion?.status==='completed'&&!events.some(e=>['response.failed','response.incomplete','error'].includes(e.type));
  calls.push({model:JSON.parse(options!.body).model,httpStatus:response.status,elapsedMs:Math.round(performance.now()-callStart),
   promptTokens:usage?.input_tokens??null,outputTokens:usage?.output_tokens??null,thinkingTokens:usage?.output_tokens_details?.reasoning_tokens??null,totalTokens:usage?.total_tokens??null,
   hasOutput,modelVersion:completion?.model??null,completionStatus:completion?.status??null,
   finishReasons:[complete?'STOP':'INCOMPLETE']});
  // Never propagate provider error bodies; they may contain credentials/details.
  return new Response(response.ok?body:JSON.stringify({error:{message:'evaluation_upstream_failed'}}),{status:response.status,headers:response.headers});
  } catch { throw new Error('evaluation_upstream_transport_failed'); }
 };
 try {
  const response=await handleAI(new URL(request.url),request,env,'synthetic-answer-device',{waitUntil:p=>pending.push(p)},{sub:'synthetic-answer-owner'},'standard');
  const body=await readBounded(response);await Promise.all(pending);
  const events=response!.ok?sseEvents(body):[];
  const result={id:testCase.id,category:testCase.category,httpStatus:response!.status,status:events.find(e=>e.ragStatus)?.ragStatus??null,
   citations:events.flatMap(e=>Array.isArray(e.citations)?e.citations:[]),answer:calls.some(c=>c.hasOutput)?events.filter(e=>typeof e.text==='string').map(e=>e.text).join(''):'',
   elapsedMs:Math.round(performance.now()-start),calls};
  result.citationDatabaseValid=result.citations.every(c=>Boolean(env.ADMIN_DB.db.prepare('SELECT 1 FROM rag_chunks WHERE account_key=? AND source_id=? AND page_number=? AND chunk_id=?').get(keyForCitations, c.sourceId,c.pageNumber,c.chunkId)));
  return {...result,...checkAnswer(testCase,result)};
 } finally {globalThis.fetch=original;env.ADMIN_DB.db.close();}
}

export function loadLocalKey(env = process.env, varsPath = new URL('../../.dev.vars',import.meta.url)) {
 if(env.OPENAI_API_KEY)return env.OPENAI_API_KEY;
 if(!fs.existsSync(varsPath as any))throw new Error('openai_key_not_configured');
 const match=fs.readFileSync(varsPath,'utf8').match(/^\s*OPENAI_API_KEY\s*=\s*(.*?)\s*$/mu);
 if(!match)throw new Error('openai_key_not_configured');
 const raw=match[1];const key=/^(["']).*\1$/u.test(raw)?raw.slice(1,-1):raw;
 if(!key || /\s/u.test(key))throw new Error('openai_key_invalid');
 return key;
}

export function selectCases(ids: any, catalog = fixture) {
 if(catalog!==fixture && catalog!==holdoutFixture)throw new Error('unknown_evaluation_fixture');
 if(!ids)return catalog.cases;
 const requested=new Set(ids.split(','));
 if([...requested].some(id=>!catalog.cases.some((c: any)=>c.id===id)))throw new Error('unknown_evaluation_case');
 return catalog.cases.filter((c: any)=>requested.has(c.id));
}

async function main() {
 if(process.env.STUDIQUO_RAG_ANSWER_REMOTE!=='true')throw new Error('remote_evaluation_requires_opt_in');
 const key=loadLocalKey();const output=process.argv[2];
 if(!output)throw new Error('output_directory_required');
 const repeat=Number(process.env.STUDIQUO_RAG_ANSWER_REPEAT??1);
 if(!Number.isInteger(repeat)||repeat<1||repeat>3)throw new Error('repeat_must_be_1_to_3');
 const set=process.env.STUDIQUO_RAG_ANSWER_SET??'baseline';
 if(!['baseline','holdout'].includes(set))throw new Error('unknown_evaluation_fixture');
 const catalog=set==='holdout'?holdoutFixture:fixture;
 const cases=selectCases(process.env.STUDIQUO_RAG_ANSWER_CASES,catalog);
 const interval=Number(process.env.STUDIQUO_RAG_ANSWER_INTERVAL_MS??0);
 if(!Number.isInteger(interval)||interval<0||interval>60000)throw new Error('invalid_evaluation_interval');
 const model=process.env.OPENAI_LUNA_MODEL;
 if(model && !/^gpt-[a-z0-9.-]{1,80}$/u.test(model))throw new Error('invalid_model');
 fs.mkdirSync(output,{recursive:true});
 const rows=[];const realFetch=globalThis.fetch;let callCount=0;
 const transport=async(url: any,options: any)=>{
  if(callCount>=100)throw new Error('evaluation_call_limit');
  callCount++;
  return realFetch(url,{...options,signal:AbortSignal.timeout(60000)});
 };
 for(let trial=1;trial<=repeat;trial++) for(const testCase of cases) {
  // Pacing is outside the measured case latency and does not change its prompt.
  if(rows.length && interval)await new Promise(resolve=>setTimeout(resolve,interval));
  let row;
  try {row={trial,...await evaluateCase(testCase,{apiKey:key,openaiFetch:transport,model})};}
  catch {row={trial,id:testCase.id,category:testCase.category,executionError:'evaluation_execution_failed',manualReview:'pending'};}
  rows.push(row);
  const completed=rows.filter(r=>!r.executionError&&r.checks.transport&&r.checks.generationComplete).length;
  fs.writeFileSync(path.join(output,'synthetic-answers.json'),JSON.stringify({syntheticOnly:true,method:'production handleAI with local synthetic retrieval and real OpenAI; manual review required',rows},null,2));
  fs.writeFileSync(path.join(output,'metrics.json'),JSON.stringify({fixtureVersion:catalog.version,requestedModel:model??'production-default',caseIds:cases.map((c: any)=>c.id),caseIntervalMs:interval,planned:cases.length*repeat,attempted:rows.length,completed,
   executionFailures:rows.filter(r=>r.executionError||!r.checks.transport||!r.checks.generationComplete).length,
   automatedChecksPass:rows.filter(r=>r.automatedChecksPass).length,manualReview:'pending',apiCalls:callCount,
   rows:rows.map(({answer,manualChecks,...metrics})=>metrics)},null,2));
  console.log(JSON.stringify({event:'answer_evaluation_progress',attempted:rows.length,completed,planned:cases.length*repeat}));
 }
}

if(process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
 main().catch(()=>{console.error('Final-answer evaluation could not complete. Check local credentials, opt-in and evaluation configuration. No provider error details were logged.');process.exitCode=1;});
}
