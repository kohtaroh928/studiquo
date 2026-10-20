// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
// Manual evaluation resume only; no scheduling or production imports.
import {createHash,randomUUID} from 'node:crypto';
import {readFile,writeFile,rename,unlink,lstat,stat,realpath,open} from 'node:fs/promises';
import {resolve,dirname,basename,join} from 'node:path';
import {pathToFileURL} from 'node:url';
import {validateFixture} from './citation-intent-evaluate.ts';
import {paragraphTask,paragraphMessages,paragraphSchema} from './paragraph-proposal.ts';
import {evaluateParagraphs} from './paragraph-proposal-live.ts';
const stamp=(x: any)=>typeof x==='string'&&Number.isFinite(Date.parse(x))&&new Date(x).toISOString()===x;
const keys=(o: any,names: any)=>o&&typeof o==='object'&&!Array.isArray(o)&&Object.keys(o).length===names.length&&names.every((k: any)=>Object.hasOwn(o,k));
export async function loadResumeFixture(profile='coverage'){
 if(profile==='transfer-complete')return (await import('./transfer-fixture.ts')).transferFixture;
 if(['multiparagraph','multiparagraph-complete'].includes(profile))return (await import('./multiparagraph-fixture.ts')).multiparagraphFixture;
 if(profile!=='coverage')throw Error('unknown_fixture_profile');
 const f=JSON.parse(await readFile(new URL('./citation-intent-fixture.json',import.meta.url),'utf8') as any);
 const ids=['split-materials','hidden-condition','formula-scope','negated-distinction'];
 f.cases=f.cases.filter((c: any)=>ids.includes(c.id));return f;
}
export function resumeWitnessPolicy(profile='coverage'){
 if(!['coverage','multiparagraph','multiparagraph-complete','transfer-complete'].includes(profile))throw Error('unknown_fixture_profile');
 return ['multiparagraph-complete','transfer-complete'].includes(profile)?'complete':'baseline';
}
export function newResumeState(fixture: any,{witnessPolicy='baseline'}: any={}){
 validateFixture(fixture);
 return {version:1,identity:createHash('sha256').update(JSON.stringify({model:'gemini-3.6-flash',protocol:2,temperature:1,thinking:'minimal',fixture,messages:fixture.cases.map((c: any)=>paragraphMessages(paragraphTask(c.question,c.references.slice(0,5)),{witnessPolicy})),schema:paragraphSchema})).digest('hex'),notBeforeUTC:null,quotaOrigin:null,quotaRecordedAtUTC:null,cases:[]};
}
export function resumePlan(fixture: any,state: any,nowMs=Date.now(),{witnessPolicy='baseline'}: any={}){
 if(!Number.isFinite(nowMs)||!keys(state,['version','identity','notBeforeUTC','quotaOrigin','quotaRecordedAtUTC','cases'])||state.version!==1||state.identity!==newResumeState(fixture,{witnessPolicy}).identity||!Array.isArray(state.cases)||!(state.notBeforeUTC===null||stamp(state.notBeforeUTC))||!(state.quotaRecordedAtUTC===null||stamp(state.quotaRecordedAtUTC))||!(state.quotaOrigin===null||['api_completed_at','legacy_mtime_hint'].includes(state.quotaOrigin)))throw Error('invalid_or_stale_state');
 const seen=new Set();
 for(const row of state.cases){
  const c=fixture.cases.find((c: any)=>c.id===row?.id);
  if(!c||seen.has(row.id)||!keys(row,['id','status','referenceIds','completedAtUTC'])||!['shadow','fallback'].includes(row.status)||!stamp(row.completedAtUTC)||!Array.isArray(row.referenceIds)||new Set(row.referenceIds).size!==row.referenceIds.length||!row.referenceIds.every((id: any)=>c.references.slice(0,5).some((r: any)=>r.id===id))||(row.status==='shadow'&&!row.referenceIds.length))throw Error('invalid_case_state');
  seen.add(row.id);
 }
 const remaining=fixture.cases.filter((c: any)=>!state.cases.some((r: any)=>r.id===c.id&&r.status==='shadow'));
 return {blocked:state.notBeforeUTC!==null&&Date.parse(state.notBeforeUTC)>nowMs,notBeforeUTC:state.notBeforeUTC,remaining,completedIds:state.cases.filter((r: any)=>r.status==='shadow').map((r: any)=>r.id)};
}
export function checkpointRow(state: any,row: any,nowMs=Date.now()){
 const next=structuredClone(state),completedAtUTC=new Date(nowMs).toISOString();
 const saved={id:row.id,status:row.status,referenceIds:row.status==='shadow'?row.shadow.referenceIds:[],completedAtUTC};
 next.cases=next.cases.filter((r: any)=>r.id!==row.id).concat(saved);
 const retry=row.provider?.error?.retrySeconds;
 if(row.provider?.httpStatus===429&&Number.isFinite(retry)&&retry>0&&retry<=86400){
  const candidate=nowMs+retry*1000,previous=next.notBeforeUTC?Date.parse(next.notBeforeUTC):0;
  if(candidate>=previous){next.notBeforeUTC=new Date(candidate).toISOString();next.quotaOrigin='api_completed_at';next.quotaRecordedAtUTC=completedAtUTC;}
 }
 return next;
}
async function assertSeparate(statePath: any,keyPath: any){
 if(resolve(statePath)===resolve(keyPath))throw Error('credential_path_collision');
 const canonicalParent=async (path: any)=>join(await realpath(dirname(resolve(path))),basename(path));
 if(await canonicalParent(statePath)===await canonicalParent(keyPath))throw Error('credential_path_collision');
 const target=await lstat(statePath).catch(e=>{if(e.code==='ENOENT')return null;throw e;});
 if(target?.isSymbolicLink())throw Error('state_symlink_rejected');
 const key=await stat(keyPath).catch(e=>{if(e.code==='ENOENT')return null;throw e;});
 if(target&&key&&target.dev===key.dev&&target.ino===key.ino)throw Error('credential_path_collision');
 if(target&&key&&(await realpath(statePath))===(await realpath(keyPath)))throw Error('credential_path_collision');
}
export async function saveResumeState(path: any,keyPath: any,state: any){
 await assertSeparate(path,keyPath);const temporary=`${path}.${randomUUID()}.tmp`;
 try{await writeFile(temporary,JSON.stringify(state,null,2)+'\n',{flag:'wx',mode:0o600});await rename(temporary,path);}
 finally{await unlink(temporary).catch(e=>{if(e.code!=='ENOENT')throw e;});}
}
export async function checkResumePaths(statePath: any,keyPath: any,reportPath: any){
 await assertSeparate(statePath,keyPath);await assertSeparate(reportPath,keyPath);
 await assertSeparate(reportPath,statePath);await assertSeparate(reportPath,`${statePath}.lock`);
}
export async function withResumeLock(statePath: any,keyPath: any,operation: any){
 const lockPath=`${statePath}.lock`;await assertSeparate(lockPath,keyPath);
 const lock=await open(lockPath,'wx',0o600);
 try{return await operation();}finally{await lock.close();await unlink(lockPath);}
}
export async function resumeEvaluation(fixture: any,state: any,{now=Date.now,loadKey,evaluate=evaluateParagraphs,save=async()=>{},intervalMs=31000,witnessPolicy='baseline'}: any={}){
 let current=structuredClone(state);const plan=resumePlan(fixture,current,now(),{witnessPolicy});
 if(plan.blocked)return {status:'quota_wait',notBeforeUTC:plan.notBeforeUTC,inheritedIds:plan.completedIds,newCalls:0,state:current,report:null};
 if(!plan.remaining.length)return {status:'already_complete',inheritedIds:plan.completedIds,newCalls:0,state:current,report:null};
 const apiKey=await loadKey();
 const report=await evaluate({...fixture,cases:plan.remaining},{apiKey,intervalMs,witnessPolicy,onRow:async (row: any)=>{current=checkpointRow(current,row,now());resumePlan(fixture,current,now(),{witnessPolicy});await save(current);}});
 return {status:'measured',inheritedIds:plan.completedIds,newCalls:report.summary.attempts,state:current,report};
}
async function main(){
 const keyPath=process.env.STUDIQUO_RAG_KEY_FILE,statePath=process.argv[2],reportPath=process.argv[3];
 if(process.env.STUDIQUO_RAG_PROPOSAL_REMOTE!=='true'||!keyPath||!statePath||!reportPath)throw Error('opt_in_required');
 await checkResumePaths(statePath,keyPath,reportPath);
 await withResumeLock(statePath,keyPath,async()=>{
 const profile=process.argv[4]??'coverage',witnessPolicy=resumeWitnessPolicy(profile),f=await loadResumeFixture(profile);
 const state=JSON.parse(await readFile(statePath,'utf8'));
 const out=await resumeEvaluation(f,state,{witnessPolicy,loadKey:async()=>{
  const m=(await readFile(keyPath,'utf8')).match(/^\s*GEMINI_API_KEY\s*=\s*(.*?)\s*$/mu);if(!m)throw Error('missing_key');let key=m[1];if(/^(["']).*\1$/u.test(key))key=key.slice(1,-1);return key;
 },save:(s: any)=>saveResumeState(statePath,keyPath,s)});
 await saveResumeState(reportPath,keyPath,{fixtureIdentity:state.identity,status:out.status,notBeforeUTC:out.notBeforeUTC??null,inheritedIds:out.inheritedIds,newCalls:out.newCalls,report:out.report});
 console.log(JSON.stringify({status:out.status,notBeforeUTC:out.notBeforeUTC??null,inheritedIds:out.inheritedIds,newCalls:out.newCalls,summary:out.report?.summary??null}));
 });
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href)main().catch(()=>{console.error('paragraph_resume_failed');process.exitCode=1;});
