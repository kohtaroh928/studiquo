import {fileURLToPath,URL} from 'node:url';
import {resolve} from 'node:path';
import {runCampaign,saveReport} from './supervisor.ts';

const args=process.argv.slice(2);
let seed=0x53545155,output=fileURLToPath(new URL('../../security-reports/worker-fuzz.json',import.meta.url)),enforce=false;
for(let i=0;i<args.length;i++){
  if(args[i]==='--enforce'){enforce=true;continue;}
  if(args[i]!=='--seed'&&args[i]!=='--output')throw Error('Unknown argument');
  const option=args[i],value=args[++i];if(!value||value.startsWith('--'))throw Error('Option value missing');
  if(option==='--seed')seed=Number(value);else output=resolve(value);
}
if(!Number.isSafeInteger(seed)||seed<0||seed>0xffffffff)throw Error('Seed must be uint32');
const reports:any[]=[];
const controller=new AbortController();
let interruption:string|undefined;
const onInterrupt=()=>{interruption='SIGINT';controller.abort();};
const onTerminate=()=>{interruption='SIGTERM';controller.abort();};
process.on('SIGINT',onInterrupt);process.on('SIGTERM',onTerminate);
try {
for(const family of ['cbor','der','json','token','http']){
  if(controller.signal.aborted)break;
  const report=await runCampaign({family,seed,signal:controller.signal,script:fileURLToPath(new URL('./campaign.ts',import.meta.url))});reports.push(report);
  console.log(JSON.stringify({family,cases:report.cases??0,findings:report.findings?.length??0,error:report.error??null}));
  if(!report.cleanupConfirmed||controller.signal.aborted)break;
}
const error=controller.signal.aborted||reports.some(r=>r.error||r.exitCode!==0),findings=reports.flatMap(r=>(r.findings??[]).map((f:any)=>({family:r.family,seed,...f})));
const result={generatedAt:new Date().toISOString(),seed,status:error?'error':findings.length?'findings':'passed',interruption,totalCases:reports.reduce((sum,r)=>sum+(r.cases??0),0),limits:{nodeHeapMiB:192,campaignTimeoutMs:45000,outputBytes:1048576},reports,findings};
if(!await saveReport(output,result)){
  console.error('worker-fuzz-report-write-failed');process.exitCode=2;
} else {
console.log(JSON.stringify({status:result.status,totalCases:result.totalCases,findingGroups:findings.length,report:output}));
process.exitCode=error?2:enforce&&findings.length?1:0;
}
} finally {
  process.removeListener('SIGINT',onInterrupt);process.removeListener('SIGTERM',onTerminate);
}
