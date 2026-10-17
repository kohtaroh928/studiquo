// Aggregate external judgments only; never infer meaning or authenticate a reviewer.
import {createHash} from 'node:crypto';
import {clarificationInputBinding,validateClarificationDecision} from './clarification-decision.mjs';
export const CLARIFICATION_REVIEW_DIMENSIONS=Object.freeze(['request','target','basis','action','evidence','provenance','intent','noInventedDetails']);
const fields=['targetState','basis','evidenceState','nextAction','inspectionPurpose'];
const hash=x=>createHash('sha256').update(JSON.stringify(x)).digest('hex');
const exact=(o,ks)=>o!==null&&typeof o==='object'&&!Array.isArray(o)&&Object.keys(o).length===ks.length&&ks.every(k=>Object.hasOwn(o,k));
const fail=c=>{throw Error('clarification_review_'+c);};
const decode=(r,max)=>{if(typeof r!=='string'||!r.trim()||Buffer.byteLength(r)>max)fail('input');try{return JSON.parse(r);}catch{fail('json');}};
function context(rawInput,rawDecision,rawOracle){
 const {input,inputHash}=clarificationInputBinding(rawInput),{decision}=validateClarificationDecision(rawInput,rawDecision),oracle=decode(rawOracle,65536);
 if(!exact(oracle,['id','inputHash','technicalState','requirements'])||typeof oracle.id!=='string'||!oracle.id||oracle.id.length>128||oracle.inputHash!==inputHash||!['ok','unsupported','failed'].includes(oracle.technicalState)||!Array.isArray(oracle.requirements)||oracle.requirements.length>16||oracle.technicalState==='ok'&&!oracle.requirements.length||oracle.technicalState!=='ok'&&oracle.requirements.length)fail('oracle');
 const ids=new Set();
 for(const r of oracle.requirements){
  if(!exact(r,['id','requestLabel','allowed','requiredTargetRefs','rationale'])||typeof r.id!=='string'||!/^r(?:[1-9]|1[0-6])$/.test(r.id)||ids.has(r.id)||typeof r.rationale!=='string'||!r.rationale.trim()||r.rationale.length>2048||!Array.isArray(r.allowed)||!r.allowed.length||r.allowed.length>8||!Array.isArray(r.requiredTargetRefs))fail('oracle');ids.add(r.id);
  for(const tuple of r.allowed){
   if(!exact(tuple,fields))fail('oracle');
   try{validateClarificationDecision(rawInput,JSON.stringify({version:1,inputHash,technicalState:'ok',decisions:[{id:'d1',requestLabel:r.requestLabel,requestRefs:['q'],...tuple,targetRefs:r.requiredTargetRefs}]}));}catch{fail('oracle');}
  }
 }
 return {input,decision,oracle,binding:{version:1,inputHash,decisionHash:hash(decision),oracleHash:hash(oracle)}};
}
export function clarificationReviewBinding(rawInput,rawDecision,rawOracle){if(arguments.length!==3)fail('arguments');return context(rawInput,rawDecision,rawOracle).binding;}
function maximum(edges,ds,rs){
 const owners=new Map();function assign(i,seen){for(let j=0;j<rs.length;j++){if(!edges[i][j]||seen.has(j))continue;seen.add(j);if(!owners.has(j)||assign(owners.get(j),seen)){owners.set(j,i);return true;}}return false;}
 ds.forEach((_,i)=>assign(i,new Set()));return [...owners].map(([j,i])=>({decisionId:ds[i].id,requirementId:rs[j].id}));
}
export function evaluateClarificationReview(rawInput,rawDecision,rawOracle,rawReview){
 if(arguments.length!==4)fail('arguments');const {decision,oracle,binding}=context(rawInput,rawDecision,rawOracle),ds=decision.decisions,rs=oracle.requirements;
 const harnessStateMatched=decision.technicalState===oracle.technicalState;
 const base={version:1,binding,harnessStateMatched,harnessAuthenticated:false,reviewerAuthenticated:false,humanGoldVerified:false,releaseAccepted:false};
 if(!harnessStateMatched||decision.technicalState!=='ok'){
  if(rawReview!==null)fail('technical_review');
  return {...base,semanticStatus:harnessStateMatched?'technical_unassessed':'technical_mismatch',reviewComplete:false,oracleRequirements:rs.length,candidateDecisions:ds.length,missing:null,extra:null,actionCounts:null};
 }
 const pairReviews=new Map(),representation=new Map(rs.map(r=>[r.id,'uncertain'])),actions=new Map();
 if(rawReview!==null){
  const r=decode(rawReview,262144);
  if(!exact(r,['version','inputHash','decisionHash','oracleHash','reviewerRole','artifactHash','representability','pairs','actionAssessments'])||Object.entries(binding).some(([k,v])=>r[k]!==v)||r.reviewerRole!=='independent_clarification_reviewer'||typeof r.artifactHash!=='string'||!/^([a-f0-9]{64})$/.test(r.artifactHash)||!Array.isArray(r.representability)||r.representability.length!==rs.length||!Array.isArray(r.pairs)||r.pairs.length>ds.length*rs.length||!Array.isArray(r.actionAssessments)||r.actionAssessments.length>ds.length)fail('shape');
  const represented=new Set();for(const p of r.representability){if(!exact(p,['requirementId','status'])||!representation.has(p.requirementId)||represented.has(p.requirementId)||!['representable','unsupported','uncertain'].includes(p.status))fail('representation');represented.add(p.requirementId);representation.set(p.requirementId,p.status);}
  for(const p of r.pairs){const key=p?.decisionId+':'+p?.requirementId;
   if(!exact(p,['decisionId','requirementId','dimensions'])||!ds.some(d=>d.id===p.decisionId)||!rs.some(r=>r.id===p.requirementId)||pairReviews.has(key)||!exact(p.dimensions,CLARIFICATION_REVIEW_DIMENSIONS)||CLARIFICATION_REVIEW_DIMENSIONS.some(k=>!['pass','fail','uncertain'].includes(p.dimensions[k])))fail('pair');pairReviews.set(key,p.dimensions);
  }
  for(const a of r.actionAssessments){const d=ds.find(d=>d.id===a?.decisionId);
   if(!exact(a,['decisionId','judgment'])||!d||actions.has(a.decisionId)||!['appropriate','unnecessary_clarification','missed_clarification','uncertain'].includes(a.judgment)||a.judgment==='unnecessary_clarification'&&d.nextAction!=='clarify_target'||a.judgment==='missed_clarification'&&d.nextAction==='clarify_target')fail('action');actions.set(a.decisionId,a.judgment);
  }
 }
 const approved=ds.map(()=>rs.map(()=>false)),possible=ds.map(()=>rs.map(()=>false)),pairCounts={approved:0,rejected:0,uncertain:0,unreviewed:0,automaticTupleMismatch:0};
 for(const [i,d] of ds.entries())for(const [j,r] of rs.entries()){
  const tuple=r.allowed.some(t=>fields.every(k=>t[k]===d[k]))&&r.requiredTargetRefs.every(ref=>d.targetRefs.includes(ref)),v=pairReviews.get(d.id+':'+r.id);
  if(!tuple){if(v&&CLARIFICATION_REVIEW_DIMENSIONS.every(k=>v[k]==='pass'))fail('tuple_conflict');pairCounts.rejected++;pairCounts.automaticTupleMismatch++;continue;}
  if(v&&CLARIFICATION_REVIEW_DIMENSIONS.some(k=>v[k]==='fail')){pairCounts.rejected++;continue;}
  possible[i][j]=true;if(v&&CLARIFICATION_REVIEW_DIMENSIONS.every(k=>v[k]==='pass')){if(['unnecessary_clarification','missed_clarification'].includes(actions.get(d.id)))fail('action_conflict');approved[i][j]=true;pairCounts.approved++;}else if(v)pairCounts.uncertain++;else pairCounts.unreviewed++;
 }
 const matched=maximum(approved,ds,rs),potential=maximum(possible,ds,rs),A=matched.length,P=potential.length,R=rs.length,T=ds.length;
 const representationCounts={representable:0,unsupported:0,uncertain:0};for(const v of representation.values())representationCounts[v]++;
 const actionCounts={appropriate:0,unnecessary_clarification:0,missed_clarification:0,uncertain:0,unreviewed:T-actions.size};for(const v of actions.values())actionCounts[v]++;
 const actionErrors=actionCounts.unnecessary_clarification+actionCounts.missed_clarification,actionComplete=actionCounts.uncertain+actionCounts.unreviewed===0,allApproved=A===R&&A===T;
 const reviewComplete=representationCounts.uncertain===0&&actionComplete&&(allApproved||pairCounts.uncertain+pairCounts.unreviewed===0);
 const semanticStatus=representationCounts.unsupported?'contract_unsupported':allApproved&&reviewComplete&&!actionErrors?'reviewed_match':P<R||P<T||actionErrors?'mismatch_detected':'pending';
 return {...base,semanticStatus,reviewComplete,reviewProvided:rawReview!==null,oracleRequirements:R,candidateDecisions:T,representationCounts,pairCounts,actionCounts,approvedMatches:A,possibleMatches:P,missing:{lower:R-P,upper:R-A},extra:{lower:T-P,upper:T-A},assignedPairs:matched,unknownKeptInDenominator:true};
}
