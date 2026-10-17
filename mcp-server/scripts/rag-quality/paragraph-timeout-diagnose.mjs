// Evaluation-only, bounded timing comparison. Public 5s limit and resume state unchanged.
import {createHash} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
import {paragraphTask,paragraphMessages,paragraphSchema,validateParagraphProposal} from './paragraph-proposal.mjs';
import {isolationRequest} from './gemini-isolate.mjs';
import {saveResumeState,withResumeLock} from './paragraph-resume.mjs';
export function timeoutSpecs(c){
 const target=paragraphTask(c.question,c.references.slice(0,5));
 const control=paragraphTask('架空計の価格と送料は？',[
  {id:'r1',sourceId:'synthetic-control',pageNumber:1,title:'合成価格',text:'価格は100円。'},
  {id:'r2',sourceId:'synthetic-control',pageNumber:2,title:'合成送料',text:'送料は別途。'}
 ]);
 return [['control_before',control],['hidden_condition_target',target],['control_after',control]].map(([id,task])=>{
  const m=paragraphMessages(task),body={systemInstruction:{parts:[{text:m[0].content}]},contents:[{role:'user',parts:[{text:m[1].content}]}],generationConfig:{temperature:1,thinkingConfig:{thinkingLevel:'minimal'},maxOutputTokens:4096,responseMimeType:'application/json',responseJsonSchema:paragraphSchema}};
  return {id,task,body};
 });
}
export async function diagnoseParagraphTimeout(c,{apiKey,fetchImpl=fetch,timeoutMs=20000,intervalMs=31000,wait=ms=>new Promise(resolve=>setTimeout(resolve,ms)),progress=()=>{}}={}){
 if(!Number.isInteger(intervalMs)||intervalMs<0||intervalMs>60000)throw Error('invalid_interval');
 const rows=[];
 for(const spec of timeoutSpecs(c)){
  if(rows.length&&intervalMs)await wait(intervalMs);
  const row=await isolationRequest(spec,{apiKey,fetchImpl,timeoutMs,proposalValidator:validateParagraphProposal});
  row.taskSnapshot=spec.task.snapshot;row.requestHash=createHash('sha256').update(JSON.stringify(spec.body)).digest('hex');row.requestBytes=Buffer.byteLength(JSON.stringify(spec.body));
  rows.push(row);progress(structuredClone(row));
  if([401,403,429].includes(row.httpStatus)||row.httpStatus>=500)break;
 }
 return {schemaVersion:1,timeoutMs,intervalMs,method:'Synthetic paragraph protocol2 timing comparison, max3 sequential calls/no retries. Same target prompt/schema/settings, diagnostic deadline only. Controls differ in content; causal attribution and DNS/TLS/service split are not established. No raw text saved, no public/resume changes.',requests:rows};
}
async function main(){
 const keyPath=process.env.STUDIQUO_RAG_KEY_FILE,reportPath=process.argv[2];
 if(process.env.STUDIQUO_RAG_PROPOSAL_REMOTE!=='true'||!keyPath||!reportPath)throw Error('opt_in_required');
 await withResumeLock(reportPath,keyPath,async()=>{
  // Validate output against credential aliases before reading the credential or calling the API.
  await saveResumeState(reportPath,keyPath,{status:'running'});
  const f=JSON.parse(await readFile(new URL('./citation-intent-fixture.json',import.meta.url),'utf8')),c=f.cases.find(c=>c.id==='hidden-condition');
  const m=(await readFile(keyPath,'utf8')).match(/^\s*GEMINI_API_KEY\s*=\s*(.*?)\s*$/mu);if(!m)throw Error('missing_key');let apiKey=m[1];if(/^(["']).*\1$/u.test(apiKey))apiKey=apiKey.slice(1,-1);
  const report=await diagnoseParagraphTimeout(c,{apiKey,progress:r=>console.log(JSON.stringify(r))});await saveResumeState(reportPath,keyPath,report);
 });
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href)main().catch(()=>{console.error('paragraph_timeout_diagnostic_failed');process.exitCode=1;});
