// Pure external-review aggregation; no IO, transport, logging or key access.
import {createHash} from 'node:crypto';
import {isDeepStrictEqual} from 'node:util';
import {evaluateUnitPlanReview} from './unit-plan-semantic-review.mjs';
import {unitTaskPlannerRequest} from './unit-task-planner-request.mjs';
const fail=()=>{throw Error('unit_artifact_audit_required');};
const exact=(o,k)=>o!==null&&typeof o==='object'&&!Array.isArray(o)&&Object.keys(o).length===k.length&&k.every(x=>Object.hasOwn(o,x));
const canonical=x=>Array.isArray(x)?x.map(canonical):x&&typeof x==='object'?Object.fromEntries(Object.keys(x).sort().map(k=>[k,canonical(x[k])])):x;
const digest=x=>createHash('sha256').update(JSON.stringify(canonical(x))).digest('hex');
const bindingKeys=['stage','completed','checkpointHash','manifestHash','runId'];
export function prepareUnitReviewArtifact(review,binding,completions,oracles){
 try{
  if(arguments.length!==4||!exact(review,[...bindingKeys,'decision','cases'])||!exact(binding,bindingKeys)||!bindingKeys.every(k=>review[k]===binding[k])||!['continue','stop'].includes(review.decision)||!Array.isArray(review.cases)||!Array.isArray(completions)||!Array.isArray(oracles))fail();
  const end=[1,4,8][binding.stage],start=[0,1,4][binding.stage];
  if(end===undefined||binding.completed!==end||review.cases.length!==end-start||completions.length!==end-start)fail();
  const summaries=[],seen=new Set();let safe=true;
  for(const c of review.cases){
   if(!exact(c,['index','review'])||!Number.isInteger(c.index)||c.index<start||c.index>=end||seen.has(c.index)||typeof c.review!=='string'||Buffer.byteLength(c.review)>262144)fail();seen.add(c.index);
   const completion=completions.find(r=>r.index===c.index);if(!completion)fail();
   const question=JSON.parse(unitTaskPlannerRequest(c.index).input[0].content[0].text).question;
   const result=evaluateUnitPlanReview(question,JSON.stringify(completion.plan),JSON.stringify(oracles[c.index]),c.review);
   if(result.semanticStatus!=='reviewed_match'||!result.reviewComplete||result.flags.contractUnsupported||result.flags.representationUncertain||Object.values(result.oracleRelativeMissing).some(x=>x!==0)||Object.values(result.oracleRelativeExtra).some(x=>x!==0))safe=false;
   summaries.push({index:c.index,...result.binding,reviewHash:digest(JSON.parse(c.review)),semanticStatus:result.semanticStatus});
  }
  if(review.decision==='continue'&&!safe)fail();summaries.sort((a,b)=>a.index-b.index);
  const artifact={version:1,review:structuredClone(review),caseSummaries:summaries};
  if(Buffer.byteLength(JSON.stringify(artifact))>2097152)fail();return artifact;
 }catch{fail();}
}
export function verifyUnitReviewArtifact(raw,binding,completions,oracles){
 try{
  if(arguments.length!==4||typeof raw!=='string'||!raw.trim()||Buffer.byteLength(raw)>2097152)fail();const parsed=JSON.parse(raw);
  if(!exact(parsed,['version','review','caseSummaries'])||parsed.version!==1)fail();
  const checked=prepareUnitReviewArtifact(parsed.review,binding,completions,oracles);if(!isDeepStrictEqual(checked,parsed))fail();return checked;
 }catch{fail();}
}
