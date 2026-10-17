// Historical Gemini transport regressions only; CLI retired. runPilot delegates to OpenAI.
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {readBounded,sseEvents} from './final-answer-evaluate.mjs';
const ids=['learning-circuit','learning-average-transfer','learning-reservation-transfer'];
export function validateSelection(caseIds=ids,styleOrder='source_first') {
 if(!Array.isArray(caseIds)||!caseIds.length||caseIds.length>ids.length||caseIds.some(id=>typeof id!=='string'||!ids.includes(id))||new Set(caseIds).size!==caseIds.length||!['source_first','explain_first'].includes(styleOrder))throw Error('invalid_pilot_selection');
 return {caseIds:[...caseIds],styleOrder,styles:styleOrder==='explain_first'?['explain','source_only']:['source_only','explain']};
}
const number=value=>Number.isSafeInteger(value)&&value>=0?value:null;
export function guardedTransport({apiKey,model='gemini-3.5-flash',fetchImpl=fetch,timeoutMs=60000,totalMs=360000,now=()=>Date.now()}) {
 if(!/^gemini-[a-z0-9.-]{1,80}$/.test(model)||typeof apiKey!=='string'||!apiKey||/\s/.test(apiKey)||!Number.isInteger(timeoutMs)||timeoutMs<1||timeoutMs>60000||!Number.isInteger(totalMs)||totalMs<1||totalMs>360000)throw Error('invalid_pilot_config');
 const deadline=now()+totalMs, calls=[];let stopped=false;
 const transport=async(url,options)=>{
  const parsed=new URL(url);
  if(stopped||calls.length>=6||now()>=deadline) {stopped=true;throw Error('pilot_stopped');}
  if(parsed.origin!=='https://generativelanguage.googleapis.com'||parsed.username||parsed.password||parsed.pathname!==`/v1beta/models/${model}:streamGenerateContent`||parsed.search!=='?alt=sse'||options.method!=='POST'||typeof options.body!=='string'||Buffer.byteLength(options.body)>512*1024){stopped=true;throw Error('invalid_pilot_request');}
  const record={httpStatus:null,elapsedMs:null,model,modelVersion:null,usage:null,finishReasons:[],error:null};calls.push(record);
  const start=now(),controller=new AbortController();let timer;
  const work=(async()=>{
   const response=await fetchImpl(url,{method:'POST',body:options.body,headers:{'content-type':'application/json','x-goog-api-key':apiKey},redirect:'error',signal:controller.signal});
   record.httpStatus=response.status;
   if(!response.ok){void response.body?.cancel().catch(()=>{});throw Error('upstream_http');}
   const text=await readBounded(response);
   if(text.includes(apiKey))throw Error('credential_in_response');
   const events=sseEvents(text),reasons=events.flatMap(e=>(e.candidates??[]).map(c=>c.finishReason).filter(Boolean));
   if(events.some(e=>e.error)||!reasons.length||reasons.some(r=>r!=='STOP')||!events.some(e=>(e.candidates??[]).some(c=>c.content?.parts?.some(p=>!p.thought&&typeof p.text==='string'&&p.text.trim()))))throw Error('incomplete_generation');
   record.finishReasons=['STOP'];
   const usage=events.map(e=>e.usageMetadata).filter(Boolean).at(-1);
   if(usage)record.usage={prompt:number(usage.promptTokenCount),output:number(usage.candidatesTokenCount),thoughts:number(usage.thoughtsTokenCount),total:number(usage.totalTokenCount)};
   const version=events.map(e=>e.modelVersion).filter(Boolean).at(-1);
   if(typeof version==='string'&&/^gemini-[a-z0-9.-]{1,80}$/.test(version))record.modelVersion=version;
   return new Response(text,{headers:{'content-type':'text/event-stream'}});
  })();
  try{return await Promise.race([work,new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('deadline')),Math.min(timeoutMs,Math.max(1,deadline-now())));})]);}
  catch{stopped=true;record.error=record.httpStatus!==null&&!(record.httpStatus>=200&&record.httpStatus<300)?'upstream_http':'transport_body_or_completion_failure';throw Error('pilot_upstream_failed');}
  finally{clearTimeout(timer);controller.abort();record.elapsedMs=Math.max(0,now()-start);}
 };
 return {transport,calls,isStopped:()=>stopped,stop:()=>{stopped=true;}};
}
export async function runPilot({apiKey,fetchImpl=fetch,onProgress=()=>{},caseIds=ids,styleOrder='source_first'}) {
 const selection=validateSelection(caseIds,styleOrder);
 const {runOpenAIPilot}=await import('./learning-openai-live.mjs');
 return runOpenAIPilot({apiKey,fetchImpl,onProgress,...selection});
}

async function main(){throw Error('historical_gemini_pilot_retired_use_learning_openai_live');}

if(process.argv[1]&&import.meta.url===pathToFileURL(path.resolve(process.argv[1])).href)main().catch(()=>{console.error('learning_pilot_failed');process.exitCode=1;});
