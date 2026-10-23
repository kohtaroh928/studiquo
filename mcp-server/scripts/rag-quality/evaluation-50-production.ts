// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
// Capture only fixed synthetic development questions through the real adapter.
// The registered handle is opaque; callers cannot supply arbitrary prompts.
import {createHash} from 'node:crypto';
import {loadEvaluation50} from './evaluation-50.ts';
import {handleAI} from '../../src/ai.ts';
import {accountKey,indexSource} from '../../src/rag/storage.ts';
import {qualityEnvironment,qualitySource} from '../../src/rag-quality-fixture.ts';
import {ragAnswerPolicy} from '../../src/rag/answer-policy.ts';
import {sseEvents} from './final-answer-evaluate.ts';
import {comparisonBoundaryFixture} from './comparison-boundary-fixture.ts';
import {loadPromptBaseline} from './prompt-baseline.ts';
import {dedupOnlyPolicy,partialOnlyPolicy} from './prompt-policy-variants.ts';
import {ragAnswerPolicy as frozenPolicy} from './baselines/20261014-policy-v1/answer-policy.ts';
const captures=new WeakMap();
let capturing=false;
const hash=(v: any)=>createHash('sha256').update(JSON.stringify(v)).digest('hex');
export const PRODUCTION_CASE_IDS=Object.freeze(['e50-versions-01','e50-pages_tables-02','e50-partial-03']);
export const POLICY_CASE_IDS=Object.freeze(['e50-versions-01','e50-partial-03','boundary-different-conditions']);
const expected=['grounded','grounded','partial'];
export function productionProbeBody(probe: any,id: any,style: any) {
 const data=captures.get(probe),body=data?.bodies.get(id+':'+style);
 if(!body)throw Error('invalid_production_probe');
 return structuredClone(body);
}
export function productionProbeMetadata(probe: any) {
 const data=captures.get(probe);if(!data)throw Error('invalid_production_probe');
 return structuredClone(data.metadata);
}
// Only known synthetic snapshots and known revisions. No caller-supplied
// requests, source text, model settings, selectors, or holdout questions.
export function capturePolicyProbe(variant: any) {
 if(!['v1','dedup','current','partial_only'].includes(variant))throw Error('invalid_policy_variant');
 const {manifest,contexts}=loadPromptBaseline(),bodies=new Map(),rows=[];
 const policy=variant==='v1'?frozenPolicy:variant==='dedup'?dedupOnlyPolicy:variant==='partial_only'?partialOnlyPolicy:ragAnswerPolicy;
 for(const [index,id] of POLICY_CASE_IDS.entries()) {
  const row=contexts.find((c: any)=>c.key===(id.startsWith('boundary-')?'boundary:':'development:')+id);
  if(!row)throw Error('missing_policy_snapshot');
  for(const style of index%2?['explain','source_only']:['source_only','explain']) {
   const fixed=policy(row.status,style);
   const body={...structuredClone(row.body),instructions:row.baseInstructions+fixed};
   if(body.model!=='gpt-6-luna'||body.max_output_tokens!==8192||body.store!==false||body.stream!==true||
      body.reasoning?.effort!=='medium'||body.service_tier!=='default'||body.tools!==undefined||body.previous_response_id!==undefined||
      Buffer.byteLength(JSON.stringify(body))>24576)throw Error('policy_capture_mismatch');
   bodies.set(id+':'+style,body);
   rows.push({caseId:id,style,status:row.status,citations:structuredClone(row.citations),inputHash:hash(body.input),
    referenceHash:hash(row.baseInstructions),policyHash:hash(fixed),requestHash:hash(body)});
  }
 }
 const probe=Object.freeze({});
 captures.set(probe,{bodies,metadata:{kind:'policy',variant,caseIds:[...POLICY_CASE_IDS],suiteId:'policy-revision-20261014',
  baselineId:manifest.id,baselineHash:hash(manifest),contextsHash:manifest.contextsHash,rubricHash:manifest.rubric.hash,
  bankHash:hash(loadEvaluation50()),rows,syntheticOnly:true,externalCaptureCalls:0}});
 return probe;
}
export async function captureProductionProbe(suite='development') {
 if(!['development','boundary'].includes(suite))throw Error('invalid_production_suite');
 if(capturing)throw Error('production_capture_busy');
 capturing=true;
 const original=globalThis.fetch;
 try {
 const bank=suite==='boundary'?comparisonBoundaryFixture():loadEvaluation50(),bodies=new Map(),rows=[];
 const caseIds=suite==='boundary'?bank.cases.map((c: any)=>c.id):[...PRODUCTION_CASE_IDS];
 // Sequential capture modifies the process-local fetch boundary temporarily.
 for(const [index,id] of caseIds.entries()) {
  const c=bank.cases.find((c: any)=>c.id===id),env=qualityEnvironment(),pending: any[]=[];
  const owner='synthetic-answer-owner',key=await accountKey(owner),sourceId=id;
  Object.assign(env,{OPENAI_API_KEY:'synthetic-capture-key',OPENAI_LUNA_MODEL:'gpt-6-luna',AI_MODERATION:'off',
   RATE_COUNTER:{getByName:()=>({bump:async()=>true,take:async()=>({ok:true,windowEndsAt:1}),give:async()=>{}})}});
  let baseline;
  try {
   await indexSource(env,key,qualitySource({sourceId,title:'合成教材 最終回答評価',pages:c.pages,totalPages:c.pages.length}));
   for(const style of index%2?['explain','source_only']:['source_only','explain']) {
    let body,calls=0;
    globalThis.fetch=async(url,options)=>{
     if(url!=='https://api.openai.com/v1/responses'||++calls!==1)throw Error('unexpected_capture_request');
     body=JSON.parse(options!.body);
     return new Response('data: {"type":"response.output_text.delta","delta":"synthetic capture"}\n\ndata: {"type":"response.completed","response":{"status":"completed"}}\n\n');
    };
    const request=new Request('https://example.test/api/ai/chat',{method:'POST',headers:{'content-type':'application/json',
     'X-Studiquo-AI-Consent':'openai-v1','X-Studiquo-Age':'adult','X-Studiquo-RAG-Consent':'rag-openai-v1'},
     body:JSON.stringify({messages:[...c.history,{role:'user',text:c.question}],model:'openai-luna',rag:{scope:{kind:'notebook',sourceId},answerStyle:style}})});
    const response=await handleAI(new URL(request.url),request,env,'synthetic-capture-device',{waitUntil:p=>pending.push(p)},{sub:owner},'standard');
    const events=sseEvents(await response!.text());await Promise.all(pending.splice(0));
    const status=events.find(e=>e.ragStatus)?.ragStatus,citations=events.flatMap(e=>e.citations??[]);
    const expectedStatus=suite==='boundary'?'grounded':expected[index];
    const policy=ragAnswerPolicy(expectedStatus,style);
    if(!response!.ok||calls!==1||status!==expectedStatus||!body?.instructions.endsWith(policy)||
     !body.instructions.includes('学習アプリ「Studiquo」')||body.model!=='gpt-6-luna'||body.store!==false||body.stream!==true||
     body.max_output_tokens!==8192||body.tools!==undefined||body.previous_response_id!==undefined||
     citations.length!==1||citations.some(c=>c.sourceId!==sourceId||c.pageNumber!==1||!env.ADMIN_DB.db.prepare(
      'SELECT 1 FROM rag_chunks WHERE account_key=? AND source_id=? AND page_number=? AND chunk_id=?').get(key,c.sourceId,c.pageNumber,c.chunkId)))throw Error('production_capture_mismatch');
    body.reasoning={effort:'medium'};body.service_tier='default';
    if(Buffer.byteLength(JSON.stringify(body))>24576)throw Error('production_capture_size_limit');
    const paired={input:body.input,base:body.instructions.slice(0,-policy.length),citations};
    if(baseline&&hash(paired)!==hash(baseline))throw Error('production_pair_mismatch');baseline??=paired;
    bodies.set(id+':'+style,structuredClone(body));
    rows.push({caseId:id,style,status,citations,inputHash:hash(body.input),referenceHash:hash(paired.base),requestHash:hash(body)});
   }
  } finally {globalThis.fetch=original;await Promise.allSettled(pending);env.ADMIN_DB.db.close();}
 }
 const probe=Object.freeze({});captures.set(probe,{bodies,metadata:{rows,kind:suite,caseIds,suiteId:bank.suiteId,bankHash:hash(bank),syntheticOnly:true,externalCaptureCalls:0}});
 return probe;
 } finally {globalThis.fetch=original;capturing=false;}
}
