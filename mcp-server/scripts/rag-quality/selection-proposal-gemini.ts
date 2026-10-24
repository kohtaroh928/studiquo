// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import {safeError} from './gemini-diagnose.ts';
// Explicit evaluation-only transport. Never imported by the public Worker.
export const PROPOSAL_MODEL='gemini-3.6-flash';
const object=(properties: any)=>({type:'object',properties,required:Object.keys(properties),additionalProperties:false});
export const proposalSchema=object({version:{type:'integer',enum:[1]},snapshot:{type:'string'},decision:{type:'string',enum:['select','abstain']},decisions:{type:'array',maxItems:5,items:object({referenceId:{type:'string'},action:{type:'string',enum:['retain','omit']},reason:{type:'string',enum:['answer','condition','supplementary','redundant','not_relevant']},spans:{type:'array',minItems:1,maxItems:3,items:object({start:{type:'integer',minimum:0},end:{type:'integer',minimum:1},quote:{type:'string',maxLength:2000}})}})}});
async function boundedJSON(response: any,signal: any,limit=65536){
 const reader=response.body?.getReader();if(!reader)throw Error('missing_body');
 let count=0;const chunks=[];
 try{while(true){if(signal.aborted)throw Error('aborted');const {done,value}=await reader.read();if(done)break;count+=value.byteLength;if(count>limit)throw Error('response_too_large');chunks.push(value);}}
 finally{await reader.cancel().catch(()=>{});reader.releaseLock();}
 const buffer=new Uint8Array(count);let offset=0;for(const c of chunks){buffer.set(c,offset);offset+=c.length;}
 return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(buffer));
}
function tokenCount(value: any){return Number.isSafeInteger(value)&&value>=0?value:null;}
export function geminiProposer({apiKey,fetchImpl=fetch,observe=()=>{},schema=proposalSchema}: any){
 if(typeof apiKey!=='string'||!apiKey||/\s/u.test(apiKey))throw Error('invalid_key');
 return async(messages: any,{signal}: any)=>{
  const metrics={requestedModel:PROPOSAL_MODEL,httpStatus:null,finishReason:null,modelVersion:null,usage:null,error:null};
  try{
   const response=await fetchImpl(`https://generativelanguage.googleapis.com/v1beta/models/${PROPOSAL_MODEL}:generateContent`,{method:'POST',redirect:'error',signal,headers:{'content-type':'application/json','x-goog-api-key':apiKey},body:JSON.stringify({systemInstruction:{parts:[{text:messages[0].content}]},contents:[{role:'user',parts:[{text:messages[1].content}]}],generationConfig:{temperature:1,thinkingConfig:{thinkingLevel:'minimal'},maxOutputTokens:4096,responseMimeType:'application/json',responseJsonSchema:schema}})});
   metrics.httpStatus=response.status;
   // Publish status before body cancellation can stall, so the quota breaker still works.
   observe({...metrics});
   if(!response.ok){
    try{metrics.error=safeError(await boundedJSON(response,signal,16384));}catch{/* Preserve status if the error body is invalid or cannot be read. */}
    throw Error('provider_http_failure');
   }
   const data=await boundedJSON(response,signal),candidate=data.candidates?.[0];
   const allowedFinish=['STOP','MAX_TOKENS','SAFETY','RECITATION','OTHER','BLOCKLIST','PROHIBITED_CONTENT','SPII'];
   metrics.finishReason=allowedFinish.includes(candidate?.finishReason)?candidate.finishReason:'unknown';
   metrics.modelVersion=typeof data.modelVersion==='string'&&/^[a-z0-9._-]{1,80}$/i.test(data.modelVersion)?data.modelVersion:null;
   if(data.usageMetadata){const u=data.usageMetadata;metrics.usage={prompt:tokenCount(u.promptTokenCount),output:tokenCount(u.candidatesTokenCount),thoughts:tokenCount(u.thoughtsTokenCount),total:tokenCount(u.totalTokenCount),cached:tokenCount(u.cachedContentTokenCount)};}
   if(candidate?.finishReason!=='STOP')throw Error('provider_unfinished');
   const raw=candidate.content?.parts?.filter((p: any)=>!p.thought&&typeof p.text==='string').map((p: any)=>p.text).join('');
   if(typeof raw!=='string'||!raw||Buffer.byteLength(raw)>32768)throw Error('invalid_model_text');
   return raw;
  }finally{observe(metrics);}
 };
}
