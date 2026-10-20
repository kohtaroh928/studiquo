// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
// Offline validation and review planning only. No credential or network access.
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {pathToFileURL} from 'node:url';
import path from 'node:path';

const dimensions=['correctness','identity','conditions','units','missing','background'];
const kinds=['document','derived','limitation','clarification'];
const digest=(value: any)=>createHash('sha256').update(JSON.stringify(value)).digest('hex');
const nonempty=(s: any)=>typeof s==='string'&&s.trim().length>0;
export function validateEvaluation50(bank: any) {
 const fail=()=>{throw Error('invalid_evaluation_50');};
 if(bank?.schemaVersion!==1||bank.syntheticOnly!==true||bank.modelEvaluated!==false||bank.humanGoldReview!=='pending'||!nonempty(bank.suiteId)||!nonempty(bank.rubricVersion)||!nonempty(bank.holdoutPolicy))fail();
 if(!Array.isArray(bank.categories)||bank.categories.length!==10||new Set(bank.categories).size!==10||bank.categories.some((c: any)=>!nonempty(c)))fail();
 for(const checks of [bank.commonChecks,bank.styleChecks?.source_only,bank.styleChecks?.explain])if(!Array.isArray(checks)||!checks.length||checks.some(x=>!nonempty(x)))fail();
 if(!Array.isArray(bank.cases)||bank.cases.length!==50)fail();
 const ids=new Set(),queries=new Set();
 for(const c of bank.cases) {
  if(!nonempty(c.id)||ids.has(c.id)||!nonempty(c.question)||queries.has(c.question)||!bank.categories.includes(c.category)||!['development','reserved_holdout'].includes(c.split))fail();
  ids.add(c.id);queries.add(c.question);
  if(!Array.isArray(c.pages)||!c.pages.length||c.pages.some((p: any,i: any)=>p.pageNumber!==i+1||!nonempty(p.text)))fail();
  if(!Array.isArray(c.history)||c.history.some((h: any)=>!['user','assistant'].includes(h.role)||!nonempty(h.text)))fail();
  if(!Array.isArray(c.forbiddenClaims)||!c.forbiddenClaims.length||c.forbiddenClaims.some((x: any)=>!nonempty(x))||!Array.isArray(c.claims)||!c.claims.length)fail();
  const claims=new Set();
  for(const a of c.claims) {
   if(!nonempty(a.id)||claims.has(a.id)||!kinds.includes(a.kind)||!dimensions.includes(a.dimension)||!nonempty(a.expected)||!Array.isArray(a.evidence))fail();
   claims.add(a.id);
   if(!a.evidence.length&&a.kind!=='clarification')fail();
   for(const e of a.evidence)if(!Number.isInteger(e.pageNumber)||!nonempty(e.quote)||!c.pages[e.pageNumber-1]?.text.includes(e.quote))fail();
  }
 }
 for(const category of bank.categories) {
  const cases=bank.cases.filter((c: any)=>c.category===category);
  if(cases.length!==5||cases.filter((c: any)=>c.split==='development').length!==3||cases.filter((c: any)=>c.split==='reserved_holdout').length!==2)fail();
 }
 return bank;
}
export function loadEvaluation50() {
 return validateEvaluation50(JSON.parse(readFileSync(new URL('./evaluation-50.json',import.meta.url),'utf8') as any));
}
// The only answer-layer inputs: no gold, criteria or forbidden-claim hints.
export function answerProbeInput(c: any) {
 return {question:c.question,history:structuredClone(c.history),references:structuredClone(c.pages)};
}
export function buildEvaluation50Plan(bank=loadEvaluation50()) {
 validateEvaluation50(bank);
 const bankHash=digest(bank),rows=[],stages=[];
 for(const split of ['development','reserved_holdout']) {
  const cases=bank.cases.filter((c: any)=>c.split===split);
  for(let offset=0;offset<cases.length;offset+=3) {
   const selected=cases.slice(offset,offset+3),stageId=`${split}-${offset/3+1}`;
   stages.push({id:stageId,split,caseIds:selected.map((c: any)=>c.id),plannedDispatches:selected.length*2,maxDispatches:6});
   for(const c of selected) {
    const index=bank.cases.findIndex((x: any)=>x.id===c.id),styles=index%2?['explain','source_only']:['source_only','explain'];
    for(const style of styles)rows.push({caseId:c.id,split,style,stageId,inputHash:digest(answerProbeInput(c)),rubricVersion:bank.rubricVersion,status:'pending',criteria:[...c.claims.map((a: any)=>({id:a.id,dimension:a.dimension,expected:a.expected,evidence:structuredClone(a.evidence),result:'pending'})),...bank.commonChecks.map((expected: any,i: any)=>({id:`common-${i+1}`,expected,result:'pending'})),...bank.styleChecks[style].map((expected: any,i: any)=>({id:`style-${i+1}`,expected,result:'pending'}))],forbiddenClaims:c.forbiddenClaims.map((expected: any)=>({expected,result:'pending'}))});
   }
  }
 }
 return {suiteId:bank.suiteId,bankHash,rubricVersion:bank.rubricVersion,mode:'offline_plan_only',networkCalls:0,plannedDispatches:100,developmentDispatches:60,reservedHoldoutDispatches:40,stages,rows,liveExecutionReady:false,remainingGates:['independent gold review and human review','fixed answer-layer adapter separate from retrieval','whole-suite input/output/cost limits using verified current rates','durable pre-dispatch journal; uncertain dispatches never automatically retried','model/prompt/evidence/settings hashes on resume','holdout not used to tune prompts']};
}
if(process.argv[1]&&import.meta.url===pathToFileURL(path.resolve(process.argv[1])).href) {
 try {const plan=buildEvaluation50Plan();console.log(JSON.stringify({suiteId:plan.suiteId,bankHash:plan.bankHash,cases:50,plannedDispatches:100,stages:plan.stages.length,networkCalls:0,liveExecutionReady:false}));}
 catch {console.error('evaluation_50_validation_failed');process.exitCode=1;}
}
