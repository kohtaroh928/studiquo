// Bounded diagnostic ladder, evaluation only. No retries or production integration.
import {readFile,writeFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
import {safeError,DIAGNOSTIC_MODEL} from './gemini-diagnose.mjs';
import {proposalSchema} from './selection-proposal-gemini.mjs';
import {proposalTask,proposalMessages,validateProposal} from './selection-proposal.mjs';
const base={temperature:1,thinkingConfig:{thinkingLevel:'minimal'},maxOutputTokens:4096};
const simple=[{role:'system',content:'Return only {"ok":true}.'},{role:'user',content:'Synthetic diagnostic.'}];
const tinySchema={type:'object',properties:{ok:{type:'boolean'}},required:['ok'],additionalProperties:false};
function body(messages,schema,json=false){return {systemInstruction:{parts:[{text:messages[0].content}]},contents:[{role:'user',parts:[{text:messages[1].content}]}],generationConfig:{...base,...(json?{responseMimeType:'application/json'}:{}),...(schema?{responseJsonSchema:schema}:{})}};}
export function isolationCases(c){
 const tiny=proposalTask('架空計の価格を教えて',[{id:'r1',sourceId:'synthetic',title:'合成資料',pageNumber:1,text:'架空計の価格は100円。送料別途。'}]);
 const full=proposalTask(c.question,c.references.slice(0,5)),tm=proposalMessages(tiny),fm=proposalMessages(full);
 return [{id:'A_text_control',body:body(simple)}, {id:'B_tiny_schema',body:body(simple,tinySchema,true)},
 {id:'C_proposal_tiny_input',body:body(tm,proposalSchema,true),task:tiny},
 {id:'D_full_without_schema',body:body(fm,null,true),task:full},
 {id:'E_full_with_schema',body:body(fm,proposalSchema,true),task:full}];
}
export function errorHint(data){
 const message=typeof data?.error?.message==='string'?data.error.message:'';
 return {capacityMentioned:/high demand|overloaded|capacity|too busy/iu.test(message),schemaMentioned:/schema|grammar|constraint/iu.test(message)};
}
async function bounded(response,signal){
 const reader=response.body?.getReader();if(!reader)throw Error('body');const chunks=[];let total=0,limit=response.ok?65536:16384;
 try{while(true){if(signal.aborted)throw Error('timeout');const {done,value}=await reader.read();if(done)break;total+=value.length;if(total>limit)throw Error('size');chunks.push(value);}}
 finally{reader.cancel().catch(()=>{});reader.releaseLock();}
 const buffer=new Uint8Array(total);let i=0;for(const c of chunks){buffer.set(c,i);i+=c.length;}return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(buffer));
}
const count=x=>Number.isSafeInteger(x)&&x>=0?x:null;
export async function isolationRequest(spec,{apiKey,fetchImpl=fetch,timeoutMs=20000,proposalValidator=validateProposal}){
 if(typeof apiKey!=='string'||!apiKey||/\s/u.test(apiKey)||!Number.isInteger(timeoutMs)||timeoutMs<1||timeoutMs>20000)throw Error('invalid_config');
 const controller=new AbortController(),start=performance.now();let timer;
 const row={id:spec.id,httpStatus:null,outcome:null,elapsedMs:null,headersMs:null,completeMs:null,phase:null,finishReason:null,modelVersion:null,usage:null,error:null,hint:null,controlValidity:null,proposalValidity:null};
 const request=(async()=>{
  const response=await fetchImpl(`https://generativelanguage.googleapis.com/v1beta/models/${DIAGNOSTIC_MODEL}:generateContent`,{method:'POST',headers:{'x-goog-api-key':apiKey,'content-type':'application/json'},redirect:'error',signal:controller.signal,body:JSON.stringify(spec.body)});
  row.httpStatus=response.status;row.headersMs=Math.round(performance.now()-start);const data=await bounded(response,controller.signal);
  if(!response.ok){row.error=safeError(data);row.hint=errorHint(data);return 'http_error';}
  const c=data.candidates?.[0],raw=c?.content?.parts?.filter(p=>!p.thought&&typeof p.text==='string').map(p=>p.text).join('');
  row.finishReason=['STOP','MAX_TOKENS','SAFETY','OTHER','RECITATION'].includes(c?.finishReason)?c.finishReason:'unknown';
  row.modelVersion=typeof data.modelVersion==='string'&&/^[a-z0-9._-]{1,80}$/iu.test(data.modelVersion)?data.modelVersion:null;
  if(data.usageMetadata){const u=data.usageMetadata;row.usage={prompt:count(u.promptTokenCount),output:count(u.candidatesTokenCount),thoughts:count(u.thoughtsTokenCount),total:count(u.totalTokenCount)};}
  if(!raw||Buffer.byteLength(raw)>32768||c.finishReason!=='STOP')return 'no_completed_answer';
  if(spec.task){const v=proposalValidator(spec.task,raw);row.proposalValidity={valid:v.valid,reason:v.reason};}
  else{try{const parsed=JSON.parse(raw);row.controlValidity={valid:parsed?.ok===true&&Object.keys(parsed).length===1};}catch{row.controlValidity={valid:false};}}
  return 'completed';
 })();
 try{row.outcome=await Promise.race([request.then(outcome=>{row.completeMs=Math.round(performance.now()-start);return outcome;}),new Promise(resolve=>{timer=setTimeout(()=>{controller.abort();resolve('timeout');},timeoutMs);})]);}
 catch{row.outcome='transport_or_body_failure';}finally{clearTimeout(timer);row.elapsedMs=Math.round(performance.now()-start);}
 row.phase=row.completeMs!==null?'complete':row.httpStatus===null?'pre_headers':'response_processing';
 return structuredClone(row);
}
export async function isolate(c,options){
 const specs=isolationCases(c),rows=[];
 for(const spec of specs){
  const row=await isolationRequest(spec,options);rows.push(row);options.progress?.(row);
  // Status takes priority even if reading/parsing the error body failed.
  if([401,403,429].includes(row.httpStatus))break;
  if(row.httpStatus>=500||row.outcome==='timeout'){
   if(spec.id!=='A_text_control'){
    const control=await isolationRequest({...specs[0],id:'F_post_control'},options);rows.push(control);options.progress?.(control);
   }
   break;
  }
 }
 return {schemaVersion:1,model:DIAGNOSTIC_MODEL,method:'Single-pass max6 calls,20sec each,no retry. Synthetic fixed inputs. A/B format differs; D/E differ only responseJsonSchema. B/C are not a schema-only causal comparison. Fixed error hints are message classifications, not proof. No raw text stored; no product changes.',requests:rows};
}
async function main(){
 if(process.env.STUDIQUO_RAG_PROPOSAL_REMOTE!=='true'||!process.env.STUDIQUO_RAG_KEY_FILE||!process.argv[2])throw Error('opt_in_required');
 const m=(await readFile(process.env.STUDIQUO_RAG_KEY_FILE,'utf8')).match(/^\s*GEMINI_API_KEY\s*=\s*(.*?)\s*$/mu);if(!m)throw Error('key_missing');let apiKey=m[1];if(/^(["']).*\1$/u.test(apiKey))apiKey=apiKey.slice(1,-1);
 const f=JSON.parse(await readFile(new URL('./citation-intent-fixture.json',import.meta.url),'utf8'));const c=f.cases.find(c=>c.id==='biology-comparison');
 const report=await isolate(c,{apiKey,progress:r=>console.log(JSON.stringify(r))});await writeFile(process.argv[2],JSON.stringify(report,null,2)+'\n');
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href)main().catch(()=>{console.error('gemini_isolation_failed');process.exitCode=1;});
