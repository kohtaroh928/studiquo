// Fixed synthetic transfer pilot. Evaluation only, no production imports except grounded policy.
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {pathToFileURL} from 'node:url';
import {transferFixture} from './transfer-fixture.mjs';
import {paragraphTask} from './paragraph-proposal.mjs';
import {measureWitnesses} from './paragraph-witness-evaluate.mjs';
import {resumePlan,saveResumeState,checkResumePaths,withResumeLock} from './paragraph-resume.mjs';
import {answerBody} from './complete-final-answer.mjs';
import {isolationRequest} from './gemini-isolate.mjs';
export function transferContexts(state,selection,now=Date.now()){
 const plan=resumePlan(transferFixture,state,now,{witnessPolicy:'complete'});
 if(plan.blocked)return {status:'quota_wait',notBeforeUTC:plan.notBeforeUTC,contexts:[]};
 if(selection.fixtureIdentity!==state.identity||selection.report?.model!=='gemini-3.6-flash'||selection.report?.witnessPolicy!=='complete'||!Array.isArray(selection.report.cases))throw Error('invalid_selection_report');
 const contexts=[];
 for(const c of transferFixture.cases){
  const row=selection.report.cases.findLast(x=>x.id===c.id),saved=state.cases.find(x=>x.id===c.id);
  if(row?.status!=='shadow'||row.requiredCoverageStatus!=='complete')return {status:'selection_incomplete',contexts:[]};
  if(saved?.status!=='shadow'||JSON.stringify(saved.referenceIds)!==JSON.stringify(row.shadow.referenceIds))throw Error('selection_state_mismatch');
  const task=paragraphTask(c.question,c.references),refs=row.shadow.referenceIds.map(id=>task.references.find(r=>r.id===id)),witnesses=row.witnessCoverage.witnessIds.map(id=>task.paragraphs.find(p=>p.id===id));
  if(measureWitnesses(c,task,refs,witnesses).missingRequired.length)throw Error('incomplete_selection');
  contexts.push({c,refs,citations:refs.map(r=>({sourceId:r.sourceId,title:r.title,pageNumber:r.pageNumber,chunkId:`evaluation-${c.id}-${r.id}`}))});
 }
 return {status:'ready',contexts};
}
export function transferAnswerIdentity(contexts,{timeoutMs=20000}={}){return createHash('sha256').update(JSON.stringify({model:'gemini-3.6-flash',timeoutMs,intervalMs:31000,bodies:contexts.map(answerBody)})).digest('hex');}
export async function runTransferAnswers(state,selection,{loadKey,fetchImpl=fetch,wait=ms=>new Promise(r=>setTimeout(r,ms)),onRow=async()=>{},now=Date.now,timeoutMs=20000}={}){
 const selected=transferContexts(state,selection,now());
 if(selected.status!=='ready')return {status:selected.status,notBeforeUTC:selected.notBeforeUTC??null,externalCalls:0,rows:[],answers:[]};
 const apiKey=await loadKey(),rows=[],answers=[];
 for(const context of selected.contexts){
  if(rows.length)await wait(31000);let answer=null;
  const row=await isolationRequest({id:context.c.id,task:context.c.id,body:answerBody(context)},{apiKey,fetchImpl,timeoutMs,proposalValidator:(_,raw)=>{
   if(raw.includes(apiKey))throw Error('credential_in_answer');answer=raw;
   // Format/availability only, never a correctness verdict.
   return {valid:true,reason:'answer_available_manual_review_required'};
  }});
  const completed=row.httpStatus===200&&row.outcome==='completed'&&row.finishReason==='STOP';
  rows.push({...row,answerAvailable:completed,qualityStatus:'not_evaluated',manualReview:'pending',citations:context.citations});
  if(completed&&answer!==null)answers.push({id:context.c.id,answer});
  await onRow({rows,answers,answerIdentity:transferAnswerIdentity(selected.contexts,{timeoutMs})});
  if([401,403,429].includes(row.httpStatus)||row.httpStatus>=500)break;
 }
 return {status:'measured',externalCalls:rows.length,rows,answers};
}
async function main(){
 const keyPath=process.env.STUDIQUO_RAG_KEY_FILE,[statePath,selectionPath,reportPath,answerPath]=process.argv.slice(2);
 if(process.env.STUDIQUO_RAG_ANSWER_REMOTE!=='true'||!keyPath||![statePath,selectionPath,reportPath,answerPath].every(Boolean))throw Error('opt_in_required');
 const paths=[statePath,selectionPath,reportPath,answerPath];
 for(let i=0;i<paths.length;i++)for(let j=i+1;j<paths.length;j++)await checkResumePaths(paths[i],keyPath,paths[j]);
 await withResumeLock(reportPath,keyPath,async()=>{
  const state=JSON.parse(await readFile(statePath,'utf8')),selection=JSON.parse(await readFile(selectionPath,'utf8'));
  const result=await runTransferAnswers(state,selection,{loadKey:async()=>{
   const m=(await readFile(keyPath,'utf8')).match(/^\s*GEMINI_API_KEY\s*=\s*(.*?)\s*$/mu);if(!m)throw Error('missing_key');let key=m[1];if(/^(["']).*\1$/u.test(key))key=key.slice(1,-1);return key;
  },onRow:async data=>{
   await saveResumeState(reportPath,keyPath,{fixtureIdentity:state.identity,answerIdentity:data.answerIdentity,productionEligible:false,planned:2,externalCalls:data.rows.length,rows:data.rows});
   await saveResumeState(answerPath,keyPath,{syntheticOnly:true,answers:data.answers});
   const row=data.rows.at(-1);console.log(JSON.stringify({attempted:data.rows.length,id:row.id,outcome:row.outcome,httpStatus:row.httpStatus}));
  }});
  if(result.status!=='measured'){await saveResumeState(reportPath,keyPath,{status:result.status,notBeforeUTC:result.notBeforeUTC,externalCalls:0});console.log(JSON.stringify({status:result.status,externalCalls:0}));}
 });
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href)main().catch(()=>{console.error('transfer_final_answer_failed');process.exitCode=1;});
