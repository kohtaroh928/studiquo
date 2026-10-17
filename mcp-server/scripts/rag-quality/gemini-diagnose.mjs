// Single synthetic availability probe. Public settings and data are untouched.
import {readFile,writeFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
export const DIAGNOSTIC_MODEL='gemini-3.6-flash';
const count=x=>(typeof x==='number'||(typeof x==='string'&&/^(?:0|[1-9][0-9]*)$/u.test(x)))&&Number.isSafeInteger(Number(x))&&Number(x)>=0?Number(x):null;
export function safeError(data){
 const e=data?.error,knownStatus=['INVALID_ARGUMENT','UNAUTHENTICATED','PERMISSION_DENIED','NOT_FOUND','RESOURCE_EXHAUSTED','UNAVAILABLE','INTERNAL','FAILED_PRECONDITION'];
 const out={status:knownStatus.includes(e?.status)?e.status:'unknown',reason:null,quotas:[],retrySeconds:null};
 for(const d of Array.isArray(e?.details)?e.details:[]){
  if(d?.['@type']==='type.googleapis.com/google.rpc.ErrorInfo'&&['API_KEY_INVALID','API_KEY_EXPIRED','BILLING_DISABLED','SERVICE_DISABLED','RATE_LIMIT_EXCEEDED'].includes(d.reason))out.reason=d.reason;
  if(d?.['@type']==='type.googleapis.com/google.rpc.RetryInfo'&&typeof d.retryDelay==='string'&&/^\d+(?:\.\d+)?s$/u.test(d.retryDelay)){const n=Number(d.retryDelay.slice(0,-1));if(Number.isFinite(n)&&n>=0&&n<=86400)out.retrySeconds=n;}
  if(d?.['@type']==='type.googleapis.com/google.rpc.QuotaFailure')for(const v of (Array.isArray(d.violations)?d.violations:[]).slice(0,10)){
   const metric=typeof v?.quotaMetric==='string'?v.quotaMetric:'',id=typeof v?.quotaId==='string'?v.quotaId:'';
   out.quotas.push({tier:metric.includes('free_tier')?'free':metric.includes('paid_tier')?'paid':'unknown',window:id.includes('PerDay')?'day':id.includes('PerMinute')?'minute':'unknown',limit:count(v?.quotaValue)});
  }
 }
 return out;
}
async function readBounded(response,signal){
 const reader=response.body?.getReader();if(!reader)throw Error('missing_body');const chunks=[];let size=0;
 try{while(true){if(signal.aborted)throw Error('timeout');const {done,value}=await reader.read();if(done)break;size+=value.length;if(size>16384)throw Error('oversize');chunks.push(value);}}
 finally{reader.cancel().catch(()=>{});reader.releaseLock();}
 const all=new Uint8Array(size);let i=0;for(const c of chunks){all.set(c,i);i+=c.length;}return JSON.parse(new TextDecoder().decode(all));
}
export async function diagnose({apiKey,fetchImpl=fetch,timeoutMs=20000}){
 if(typeof apiKey!=='string'||!apiKey||/\s/u.test(apiKey)||!Number.isInteger(timeoutMs)||timeoutMs<1||timeoutMs>20000)throw Error('invalid_diagnostic_config');
 const controller=new AbortController(),start=performance.now();let timer;
 const result={requestedModel:DIAGNOSTIC_MODEL,httpStatus:null,outcome:null,elapsedMs:null,modelVersion:null,usage:null,error:null};
 const request=(async()=>{
  const response=await fetchImpl(`https://generativelanguage.googleapis.com/v1beta/models/${DIAGNOSTIC_MODEL}:generateContent`,{method:'POST',redirect:'error',signal:controller.signal,headers:{'content-type':'application/json','x-goog-api-key':apiKey},body:JSON.stringify({contents:[{role:'user',parts:[{text:'Return only the word OK.'}]}],generationConfig:{maxOutputTokens:256}})});
  result.httpStatus=response.status;const data=await readBounded(response,controller.signal);
  if(!response.ok){result.error=safeError(data);return 'http_error';}
  const c=data.candidates?.[0],hasText=c?.content?.parts?.some(p=>!p.thought&&typeof p.text==='string'&&p.text.trim());
  result.modelVersion=typeof data.modelVersion==='string'&&/^[a-z0-9._-]{1,80}$/iu.test(data.modelVersion)?data.modelVersion:null;
  if(data.usageMetadata){const u=data.usageMetadata;result.usage={prompt:count(u.promptTokenCount),output:count(u.candidatesTokenCount),thoughts:count(u.thoughtsTokenCount),total:count(u.totalTokenCount)};}
  return hasText&&c.finishReason==='STOP'?'available':'no_completed_answer';
 })();
 try{result.outcome=await Promise.race([request,new Promise(resolve=>{timer=setTimeout(()=>{controller.abort();resolve('timeout');},timeoutMs);})]);}
 catch{result.outcome='transport_or_body_failure';}finally{clearTimeout(timer);result.elapsedMs=Math.round(performance.now()-start);}
 // Copy at deadline: late activity may not rewrite the reported observation.
 return structuredClone(result);
}
async function main(){
 if(process.env.STUDIQUO_RAG_PROPOSAL_REMOTE!=='true'||!process.env.STUDIQUO_RAG_KEY_FILE||!process.argv[2])throw Error('diagnostic_opt_in_required');
 const m=(await readFile(process.env.STUDIQUO_RAG_KEY_FILE,'utf8')).match(/^\s*GEMINI_API_KEY\s*=\s*(.*?)\s*$/mu);if(!m)throw Error('missing_key');let apiKey=m[1];if(/^(["']).*\1$/u.test(apiKey))apiKey=apiKey.slice(1,-1);
 const result=await diagnose({apiKey});await writeFile(process.argv[2],JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify(result));
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href)main().catch(()=>{console.error('gemini_diagnostic_failed');process.exitCode=1;});
