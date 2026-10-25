// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import {readFile,writeFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
import {validateFixture,measureSelection} from './citation-intent-evaluate.ts';
import {proposalTask,runProposal} from './selection-proposal.ts';
import {geminiProposer,PROPOSAL_MODEL} from './selection-proposal-gemini.ts';
export async function evaluateLive(fixture: any,{apiKey,fetchImpl=fetch,progress=()=>{}}: any){
 validateFixture(fixture);if(fixture.cases.length>20)throw Error('call_budget_exceeded');
 // Validate every input before any external call, and do not pass labels into model input.
 const tasks=fixture.cases.map((c: any)=>proposalTask(c.question,c.references.slice(0,5))),cases: any[]=[];
 for(let i=0;i<tasks.length;i++){
  const c=fixture.cases[i],task=tasks[i],start=performance.now();let metrics=null;
  const out=await runProposal(task,geminiProposer({apiKey,fetchImpl,observe:(m: any)=>{metrics=m;}}),{timeoutMs:5000});
  const row={id:c.id,split:c.split,status:out.status,reason:out.reason,elapsedMs:Math.round(performance.now()-start),provider:metrics,productionEligible:out.productionEligible,baseline:measureSelection(c,task.references),shadow:measureSelection(c,out.shadowReferences)};
  cases.push(row);progress({id:row.id,status:row.status,reason:row.reason,elapsedMs:row.elapsedMs,httpStatus:metrics?.httpStatus??null});
  // A quota/auth failure invalidates further measurements; stop without retry.
  if([401,403,429].includes(metrics?.httpStatus)||metrics?.httpStatus>=500)break;
 }
 const valid=cases.filter(c=>c.status==='shadow'),sum=(rows: any,key: any)=>rows.reduce((n: any,c: any)=>n+c.shadow[key],0),times=cases.map(c=>c.elapsedMs).sort((a,b)=>a-b);
 return {schemaVersion:1,model:PROPOSAL_MODEL,labelStatus:fixture.labelStatus,method:'Direct Gemini selection-only shadow. Fixed synthetic authorized candidates; not Cloudflare retrieval or final answer evaluation. Single sequential pass, max20 calls, no retry, 5sec per request; stop on HTTP401/403/429/5xx. Model3.6, temperature1, minimal thinking. Labels never sent. No product integration.',summary:{plannedCases:tasks.length,attempts:cases.length,notAttempted:tasks.length-cases.length,stoppedEarly:cases.length<tasks.length,validProposals:valid.length,fallbacks:cases.length-valid.length,validButMissingRequired:valid.filter(c=>c.shadow.missingRequired.length).length,validRequiredFacts:sum(valid,'requiredFacts'),validTotalRequiredFacts:sum(valid,'totalRequiredFacts'),allRequiredFacts:sum(cases,'requiredFacts'),allTotalRequiredFacts:sum(cases,'totalRequiredFacts'),baselineReferences:cases.reduce((n,c)=>n+c.baseline.referenceCount,0),shadowReferences:sum(cases,'referenceCount'),medianMs:times.length?(times[Math.floor((times.length-1)/2)]+times[Math.floor(times.length/2)])/2:null,minMs:times[0]??null,maxMs:times.at(-1)??null,usageObservedCalls:cases.filter(c=>c.provider?.usage).length,usageTotals:Object.fromEntries(['prompt','output','thoughts','total','cached'].map(k=>[k,cases.reduce((n,c)=>n+(c.provider?.usage?.[k]??0),0)])),estimatedCostUSD:null,costNote:'Cost is not computed by this runner. Verify current model rates and observed usage separately. Usage-less failures/timeouts may still be billed. Not a billing statement.'},cases};
}
async function main(){
 if(process.env.STUDIQUO_RAG_PROPOSAL_REMOTE!=='true')throw Error('remote_opt_in_required');
 const varsPath=process.env.STUDIQUO_RAG_KEY_FILE,output=process.argv[2];if(!varsPath||!output)throw Error('paths_required');
 const match=(await readFile(varsPath,'utf8')).match(/^\s*GEMINI_API_KEY\s*=\s*(.*?)\s*$/mu);if(!match)throw Error('key_not_configured');
 let apiKey=match[1];if(/^(["']).*\1$/u.test(apiKey))apiKey=apiKey.slice(1,-1);
 const fixture=JSON.parse(await readFile(new URL('./citation-intent-fixture.json',import.meta.url),'utf8') as any);
 const report=await evaluateLive(fixture,{apiKey,progress:(p: any)=>console.log(JSON.stringify(p))});
 await writeFile(output,JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report.summary));
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href)main().catch(()=>{console.error('proposal_evaluation_failed');process.exitCode=1;});
