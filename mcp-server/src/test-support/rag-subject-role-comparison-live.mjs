import {comparisonResult,hash,mockBatch} from './rag-subject-role-comparison.mjs';
import {subjectRoleComparisonLiveManifest} from '../../scripts/rag-quality/subject-role-comparison-live-contract.mjs';
export {hash,mockBatch};
export const syntheticKey='synthetic_evaluation_token_123456789';
export function rawResponse(job){
 const r=comparisonResult(job);return {object:'response',status:'completed',error:null,incomplete_details:null,model:r.model,
  output:[{type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:JSON.stringify(r.plan)}]}],
  usage:{input_tokens:r.usage.input,output_tokens:r.usage.output,total_tokens:r.usage.total,output_tokens_details:{reasoning_tokens:r.usage.reasoning}}};
}
export function mockFetch(calls,handler){
 const m=subjectRoleComparisonLiveManifest();return async(url,options)=>{
  const job=m.jobs.find(j=>j.requestHash===hash(options.body));if(!job)throw Error('synthetic unbound body');calls.push({job,url,options});
  return handler?handler(job,url,options):new Response(JSON.stringify(rawResponse(job)),{headers:{'content-type':'application/json'}});
 };
}
