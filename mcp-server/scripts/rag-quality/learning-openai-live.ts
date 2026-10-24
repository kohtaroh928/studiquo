// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
// Fixed synthetic probes through production handleAI; never a production deploy.
import fs from 'node:fs';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';
import {handleAI} from '../../src/ai.ts';
import {accountKey,indexSource} from '../../src/rag/storage.ts';
import {qualityEnvironment,qualitySource} from '../../src/rag-quality-fixture.ts';
import {learningPairs} from './learning-fixture.ts';
import {LEARNING_RUBRIC_VERSION,learningReviewChecks} from './learning-rubric.ts';
import {ragAnswerPolicy} from '../../src/rag/answer-policy.ts';
import {readBounded,sseEvents} from './final-answer-evaluate.ts';

const catalog=['learning-reservation-transfer','learning-circuit','learning-average-transfer','learning-print-batch-v4','learning-heat-symbolic-v4','learning-studio-injection-v4','learning-transport-paragraphs','learning-partial-devices','learning-density-background'];
const hash=(v: any)=>createHash('sha256').update(JSON.stringify(v)).digest('hex');
const safeNumber=(v: any)=>Number.isSafeInteger(v)&&v>=0?v:null;
export function selectOpenAIProbes(caseIds=catalog.slice(0,2),styleOrder='explain_first') {
 if(!Array.isArray(caseIds)||!caseIds.length||caseIds.length>3||caseIds.some(id=>!catalog.includes(id))||new Set(caseIds).size!==caseIds.length||!['explain_first','source_first'].includes(styleOrder))throw Error('invalid_pilot_selection');
 return {caseIds:[...caseIds],styleOrder,styles:styleOrder==='explain_first'?['explain','source_only']:['source_only','explain']};
}
export function loadOpenAIKey(env=process.env,varsPath=new URL('../../.dev.vars',import.meta.url)) {
 let key=env.OPENAI_API_KEY;
 if(!key&&fs.existsSync(varsPath as any)) {
  const raw=fs.readFileSync(varsPath,'utf8').match(/^\s*OPENAI_API_KEY\s*=\s*(.*?)\s*$/mu)?.[1];
  key=raw&&/^(["']).*\1$/u.test(raw)?raw.slice(1,-1):raw;
 }
 if(typeof key!=='string'||!key||/\s/u.test(key))throw Error('openai_key_not_configured');
 return key;
}
export function guardedOpenAITransport({apiKey,fetchImpl=fetch,timeoutMs=60000,totalMs=360000,now=()=>Date.now()}: any) {
 if(typeof apiKey!=='string'||!apiKey||/\s/u.test(apiKey)||!Number.isInteger(timeoutMs)||timeoutMs<1||timeoutMs>60000||!Number.isInteger(totalMs)||totalMs<1||totalMs>360000)throw Error('invalid_pilot_config');
 const deadline=now()+totalMs,calls: any[]=[];let stopped=false;
 const transport=async(url: any,options: any)=>{
  if(stopped||calls.length>=6||now()>=deadline){stopped=true;throw Error('pilot_stopped');}
  let body;
  try {
   if(url!=='https://api.openai.com/v1/responses'||options?.method!=='POST'||typeof options.body!=='string'||Buffer.byteLength(options.body)>512*1024)throw Error();
   body=JSON.parse(options.body);
   if(body.model!=='gpt-6-luna'||body.store!==false||body.stream!==true||body.previous_response_id!==undefined||body.tools!==undefined||typeof body.instructions!=='string')throw Error();
  }catch{stopped=true;throw Error('invalid_pilot_request');}
  const record={httpStatus:null,elapsedMs:null,requestedModel:body.model,returnedModel:null,completionStatus:null,usage:null,error:null};calls.push(record);
  const start=now(),controller=new AbortController();let timer;
  try {
   const work=(async()=>{
    const response=await fetchImpl(url,{method:'POST',body:options.body,headers:{'content-type':'application/json',authorization:`Bearer ${apiKey}`},redirect:'error',signal:controller.signal});
    record.httpStatus=response.status;
    if(!response.ok){void response.body?.cancel().catch(()=>{});throw Error();}
    const text=await readBounded(response);
    if(text.includes(apiKey))throw Error();
    const events=sseEvents(text),completed=events.filter(e=>e.type==='response.completed');
    if(completed.length!==1||events.some(e=>['error','response.failed','response.incomplete'].includes(e.type))||completed[0].response?.status!=='completed'||!events.some(e=>e.type==='response.output_text.delta'&&typeof e.delta==='string'&&e.delta.trim()))throw Error();
    const result=completed[0].response;record.completionStatus='completed';
    if(typeof result.model==='string'&&/^gpt-[a-z0-9.-]{1,80}$/u.test(result.model))record.returnedModel=result.model;
    if(result.usage)record.usage={input:safeNumber(result.usage.input_tokens),output:safeNumber(result.usage.output_tokens),reasoning:safeNumber(result.usage.output_tokens_details?.reasoning_tokens),total:safeNumber(result.usage.total_tokens)};
    return new Response(text,{headers:{'content-type':'text/event-stream'}});
   })();
   return await Promise.race([work,new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error()),Math.min(timeoutMs,Math.max(1,deadline-now())));})]);
  }catch{stopped=true;record.error=record.httpStatus!==null&&(record.httpStatus<200||record.httpStatus>=300)?'upstream_http':'transport_body_or_completion_failure';throw Error('pilot_upstream_failed');}
  finally{clearTimeout(timer);controller.abort();record.elapsedMs=Math.max(0,now()-start);}
 };
 return {transport,calls,isStopped:()=>stopped,stop:()=>{stopped=true;}};
}
export async function runOpenAIPilot({apiKey,fetchImpl=fetch,caseIds,styleOrder,onProgress=()=>{}}: any) {
 const selection=selectOpenAIProbes(caseIds,styleOrder),gate=guardedOpenAITransport({apiKey,fetchImpl}),rows=[];
 for(const id of selection.caseIds) {
  if(gate.isStopped())break;
  const pair=learningPairs.find((p: any)=>p.id===id),env=qualityEnvironment(),pending: any[]=[],owner='synthetic-answer-owner',key=await accountKey(owner),sourceId=`answer-${id}`;
  Object.assign(env,{OPENAI_API_KEY:apiKey,OPENAI_LUNA_MODEL:'gpt-6-luna',AI_MODERATION:'off',AI_RETRY_BASE_MS:0,
   RATE_COUNTER:{getByName:()=>({bump:async()=>true,take:async()=>({ok:true,windowEndsAt:Date.now()+60000}),give:async()=>{}, reserve: async () => ({ ok: true, windowEndsAt: Date.now()+60000 }), release: async () => true})}});
  const original=globalThis.fetch;let baseline: any;
  try {
   await indexSource(env,key,qualitySource({sourceId,title:'合成教材 最終回答評価',totalPages:pair.pages.length,pages:pair.pages.map((text: any,i: any)=>({pageNumber:i+1,text}))}));
   for(const style of selection.styles) {
    if(gate.isStopped())break;
    let inputHash,referenceHash,configHash;
    globalThis.fetch=async(url,options)=>{
     const body=JSON.parse(options!.body),policy=ragAnswerPolicy(pair.expectedStatus,style);
     if(typeof body.instructions!=='string'||!body.instructions.endsWith(policy)){gate.stop();throw Error('policy_mismatch');}
     inputHash=hash(body.input);referenceHash=hash(body.instructions.slice(0,-policy.length));
     const {instructions,input,...config}=body;configHash=hash(config);
     if(baseline&&(baseline.inputHash!==inputHash||baseline.referenceHash!==referenceHash||baseline.configHash!==configHash)){gate.stop();throw Error('snapshot_mismatch');}
     return gate.transport(url,options);
    };
    const start=performance.now(),callStart=gate.calls.length;let row;
    try {
     const request=new Request('https://example.test/api/ai/chat',{method:'POST',headers:{'content-type':'application/json','X-Studiquo-AI-Consent':'openai-v1','X-Studiquo-Age':'adult','X-Studiquo-RAG-Consent':'rag-openai-v1'},body:JSON.stringify({messages:[{role:'user',text:pair.query}],model:'openai-luna',rag:{scope:{kind:'notebook',sourceId},answerStyle:style}})});
     const response=await handleAI(new URL(request.url),request,env,'synthetic-pilot-device',{waitUntil:p=>pending.push(p)},{sub:owner},'standard');
     const events=response!.ok?sseEvents(await readBounded(response)):[],citations=events.flatMap(e=>e.citations??[]),answer=events.filter(e=>typeof e.text==='string').map(e=>e.text).join('');
     if(answer.includes(apiKey)){gate.stop();throw Error('unsafe_answer');}
     const calls=gate.calls.slice(callStart),citationDatabaseValid=citations.every(c=>Boolean(env.ADMIN_DB.db.prepare('SELECT 1 FROM rag_chunks WHERE account_key=? AND source_id=? AND page_number=? AND chunk_id=?').get(key,c.sourceId,c.pageNumber,c.chunkId)));
     const checks={transport:response!.ok,generationComplete:calls.length===1&&calls[0].completionStatus==='completed',retrievalStatus:events.find(e=>e.ragStatus)?.ragStatus===pair.expectedStatus,citationPages:JSON.stringify([...new Set(citations.map(c=>c.pageNumber))].sort())===JSON.stringify(pair.expectedPages),citationIdentity:citationDatabaseValid&&citations.every(c=>c.sourceId===sourceId&&c.title==='合成教材 最終回答評価'),requiredFacts:null,forbiddenClaims:null};
     row={id,style,httpStatus:response!.status,answer,citations,inputHash,referenceHash,configHash,calls,elapsedMs:Math.round(performance.now()-start),checks,automatedChecksPass:Object.values(checks).filter(v=>v!==null).every(Boolean),semanticAutomatedChecks:'not_configured',manualReview:'pending',rubricVersion:LEARNING_RUBRIC_VERSION,manualChecks:learningReviewChecks(pair,style),legacyManualChecks:[...pair.manualChecks.common,...pair.manualChecks[style]]};
     if(!row.automatedChecksPass||baseline&&hash(baseline.citations)!==hash(citations))gate.stop();baseline??=row;
    }catch{gate.stop();row={id,style,error:'pilot_case_failed',manualReview:'pending'};}
    finally{await Promise.allSettled(pending.splice(0));}
    rows.push(row);onProgress({id,style,completed:Boolean(row.checks?.generationComplete),dispatches:gate.calls.length});
   }
  }finally{globalThis.fetch=original;env.ADMIN_DB.db.close();}
 }
 return {syntheticOnly:true,method:'production handleAI + fixed local synthetic retrieval + real OpenAI; moderation disabled for fixed synthetic probes only',model:'gpt-6-luna',caseIds:selection.caseIds,styleOrder:selection.styleOrder,requested:selection.caseIds.length*2,attempted:rows.length,dispatches:gate.calls.length,stopped:gate.isStopped(),rows,calls:structuredClone(gate.calls),manualReview:'pending'};
}
async function main() {
 if(process.env.STUDIQUO_RAG_OPENAI_REMOTE!=='true')throw Error('remote_opt_in_required');
 const selection=selectOpenAIProbes(process.env.STUDIQUO_RAG_OPENAI_CASES?.split(','),process.env.STUDIQUO_RAG_OPENAI_STYLE_ORDER);
 const apiKey=loadOpenAIKey(process.env,process.env.STUDIQUO_RAG_OPENAI_KEY_FILE??new URL('../../.dev.vars',import.meta.url));
 const output=process.argv[2];if(!output)throw Error('output_required');fs.mkdirSync(output,{mode:0o700});
 const result=await runOpenAIPilot({apiKey,...selection,onProgress:(p: any)=>console.log(JSON.stringify(p))});
 const text=JSON.stringify(result,null,2)+'\n';if(text.includes(apiKey))throw Error('unsafe_artifact');fs.writeFileSync(path.join(output,'synthetic-results.json'),text,{flag:'wx',mode:0o600});
 console.log(JSON.stringify({requested:result.requested,attempted:result.attempted,dispatches:result.dispatches,stopped:result.stopped}));
}
if(process.argv[1]&&import.meta.url===pathToFileURL(path.resolve(process.argv[1])).href)main().catch(()=>{console.error('openai_learning_pilot_failed');process.exitCode=1;});
