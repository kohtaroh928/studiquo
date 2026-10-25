// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import {readFile,writeFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
import {validateFixture,measureSelection} from './citation-intent-evaluate.ts';
import {paragraphTask,runParagraphProposal,paragraphSchema} from './paragraph-proposal.ts';
import {geminiProposer,PROPOSAL_MODEL} from './selection-proposal-gemini.ts';
import {measureWitnesses} from './paragraph-witness-evaluate.ts';
export async function evaluateParagraphs(fixture: any,{apiKey,fetchImpl=fetch,progress=()=>{},onRow=async()=>{},intervalMs=0,witnessPolicy='baseline',wait=(ms: any)=>new Promise(resolve=>setTimeout(resolve,ms))}: any){
 if(!Number.isInteger(intervalMs)||intervalMs<0||intervalMs>60000)throw Error('invalid_interval');
 validateFixture(fixture);if(fixture.cases.length>20)throw Error('call_budget_exceeded');
 const tasks=fixture.cases.map((c: any)=>paragraphTask(c.question,c.references.slice(0,5))),cases=[];
 for(let i=0;i<tasks.length;i++){
  if(i&&intervalMs)await wait(intervalMs);
  const c=fixture.cases[i],t=tasks[i],start=performance.now();let metrics=null;
  const out=await runParagraphProposal(t,geminiProposer({apiKey,fetchImpl,schema:paragraphSchema,observe:(m: any)=>{metrics=m;}}),{witnessPolicy});
  const row={id:c.id,split:c.split,status:out.status,reason:out.reason,elapsedMs:Math.round(performance.now()-start),provider:metrics?structuredClone(metrics):null,productionEligible:out.productionEligible,baseline:measureSelection(c,t.references),shadow:measureSelection(c,out.shadowReferences),witnessCount:out.witnesses.length};
  row.witnessCoverage=out.status==='shadow'?measureWitnesses(c,t,out.shadowReferences,out.witnesses):null;
  row.requiredCoverageStatus=out.status!=='shadow'?'not_evaluated':row.shadow.missingRequired.length||row.witnessCoverage.missingRequired.length?'incomplete':'complete';
  cases.push(row);await onRow(row);progress({id:row.id,status:row.status,reason:row.reason,elapsedMs:row.elapsedMs,httpStatus:metrics?.httpStatus??null});
  if([401,403,429].includes(metrics?.httpStatus)||metrics?.httpStatus>=500)break;
 }
 const valid=cases.filter(c=>c.status==='shadow');
 return {schemaVersion:2,model:PROPOSAL_MODEL,intervalMs,witnessPolicy,labelStatus:fixture.labelStatus,method:'Paragraph-ID selection-only shadow on fixed synthetic references. Full excerpts retained. Witness coverage measures exact draft-labelled spans, not semantic entailment. No labels sent, no product integration. Sequential/no retry/max20 calls/5sec; stop on auth/quota/5xx.',summary:{planned:tasks.length,attempts:cases.length,notAttempted:tasks.length-cases.length,valid:valid.length,completeRequiredCoverage:valid.filter(c=>c.requiredCoverageStatus==='complete').length,incompleteRequiredCoverage:valid.filter(c=>c.requiredCoverageStatus==='incomplete').length,fallbacks:cases.length-valid.length,validButMissingRequired:valid.filter(c=>c.shadow.missingRequired.length).length,validRequiredFacts:valid.reduce((n,c)=>n+c.shadow.requiredFacts,0),validTotalRequiredFacts:valid.reduce((n,c)=>n+c.shadow.totalRequiredFacts,0),validWitnessMissingRequired:valid.filter(c=>c.witnessCoverage.missingRequired.length).length,validWitnessRequiredFacts:valid.reduce((n,c)=>n+c.witnessCoverage.requiredFacts,0),validWitnessTotalRequiredFacts:valid.reduce((n,c)=>n+c.witnessCoverage.totalRequiredFacts,0),baselineReferences:cases.reduce((n,c)=>n+c.baseline.referenceCount,0),shadowReferences:cases.reduce((n,c)=>n+c.shadow.referenceCount,0)},cases};
}
async function main(){
 if(process.env.STUDIQUO_RAG_PROPOSAL_REMOTE!=='true'||!process.env.STUDIQUO_RAG_KEY_FILE||!process.argv[2])throw Error('opt_in_required');
 const m=(await readFile(process.env.STUDIQUO_RAG_KEY_FILE,'utf8')).match(/^\s*GEMINI_API_KEY\s*=\s*(.*?)\s*$/mu);if(!m)throw Error('missing_key');let apiKey=m[1];if(/^(["']).*\1$/u.test(apiKey))apiKey=apiKey.slice(1,-1);
 const f=JSON.parse(await readFile(new URL('./citation-intent-fixture.json',import.meta.url),'utf8') as any);
 const ids=['split-materials','hidden-condition','formula-scope','negated-distinction'];f.cases=f.cases.filter((c: any)=>ids.includes(c.id));
 const report=await evaluateParagraphs(f,{apiKey,intervalMs:31000,progress:(p: any)=>console.log(JSON.stringify(p))});await writeFile(process.argv[2],JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report.summary));
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href)main().catch(()=>{console.error('paragraph_evaluation_failed');process.exitCode=1;});
