// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import {readFile,writeFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
import {queryPlan} from '../../src/rag/query.ts';
import {compoundReferenceSubject} from '../../src/rag/reference-selection.ts';
import {coversSubject} from '../../src/rag/ranking.ts';
const roles=['required','supporting','off_intent'];
const nonempty=(value: any)=>typeof value==='string'&&value.trim().length>0;
export function validateFixture(fixture: any){
 if(!fixture||fixture.schemaVersion!==1||!Array.isArray(fixture.cases)||!fixture.cases.length)throw Error('invalid_fixture');
 const ids=new Set();
 for(const c of fixture.cases){
  if(!c||!nonempty(c.id)||ids.has(c.id)||!['dev','holdout'].includes(c.split)||!nonempty(c.question)||!Array.isArray(c.references)||!c.references.length||c.references.length>10||!Array.isArray(c.facts))throw Error('invalid_case');ids.add(c.id);
  if(c.references.some((r: any)=>!r||!nonempty(r.id)||!nonempty(r.sourceId)||!nonempty(r.title)||!nonempty(r.text)||!Number.isSafeInteger(r.pageNumber)||r.pageNumber<1))throw Error('invalid_reference');
  const keys=new Set(c.references.map((r: any)=>r.id));if(keys.size!==c.references.length)throw Error('duplicate_reference');
  if(!c.facts.some((f: any)=>f&&f.role==='required'))throw Error('missing_required_labels');
  const facts=new Set();
  for(const f of c.facts){
   if(!f||!nonempty(f.id)||facts.has(f.id)||typeof f.protected!=='boolean'||!roles.includes(f.role)||!Array.isArray(f.evidence)||!f.evidence.length)throw Error('invalid_fact');facts.add(f.id);
   for(const e of f.evidence){if(!e)throw Error('invalid_original_span');const r=c.references.find((r: any)=>r.id===e.referenceId);
    if(!r||!Number.isInteger(e.start)||!Number.isInteger(e.end)||e.start<0||e.end<=e.start||e.end>r.text.length||!nonempty(e.quote)||r.text.slice(e.start,e.end)!==e.quote)throw Error('invalid_original_span');
   }
  }
 }
 return fixture;
}
function containedSamePage(refs: any){
 // Evaluation only. Never infer equivalence across pages, sources or normalized text.
 return refs.filter((r: any,i: any)=>!refs.some((other: any,j: any)=>j!==i&&other.sourceId===r.sourceId&&other.pageNumber===r.pageNumber&&
  other.text.includes(r.text)&&(other.text.length>r.text.length||(other.text===r.text&&j<i))));
}
export function shadowSelection(c: any,policy: any){
 const baseline=c.references.slice(0,5);
 if(policy==='baseline')return baseline;
 if(policy==='same_page_containment')return containedSamePage(baseline);
 if(policy==='topic_representatives'){
  const p=queryPlan(c.question),groups=p.coverageGroups.length?p.coverageGroups:[compoundReferenceSubject(c.question)].filter(Boolean);
  if(!groups.length)return baseline;
  return [...new Set(groups.map((g: any)=>baseline.find((r: any)=>coversSubject(r,g))).filter(Boolean))];
 }
 if(policy==='prefer_direct_headings'){
  if(/具体例|例を|例えば|実験|観察|手順|検証/u.test(c.question))return baseline;
  const retained=baseline.filter((r: any)=>!/(?:具体例|観察|実験|応用)/u.test(r.title+'\n'+r.text.split('\n')[0]));
  return retained.length?retained:baseline;
 }
 throw Error('unknown_policy');
}
function hasFact(refs: any,fact: any){return fact.evidence.some((e: any)=>refs.some((r: any)=>r.id===e.referenceId&&r.text.slice(e.start,e.end)===e.quote));}
export function measureSelection(c: any,refs: any){
 const roleCount=(role: any)=>c.facts.filter((f: any)=>f.role===role&&hasFact(refs,f)).length;
 const required=c.facts.filter((f: any)=>f.role==='required');
 const protectedFacts=required.filter((f: any)=>f.protected);
 return {referenceIds:refs.map((r: any)=>r.id),pages:refs.map((r: any)=>r.pageNumber),referenceCount:refs.length,distinctSources:new Set(refs.map((r: any)=>r.sourceId)).size,textCharacters:refs.reduce((n: any,r: any)=>n+r.text.length,0),
  requiredFacts:roleCount('required'),totalRequiredFacts:required.length,missingRequired:required.filter((f: any)=>!hasFact(refs,f)).map((f: any)=>f.id),
  protectedRequiredMissing:protectedFacts.filter((f: any)=>!hasFact(refs,f)).map((f: any)=>f.id),supportingFacts:roleCount('supporting'),offIntentFacts:roleCount('off_intent')};
}
export function labelledLowerBound(c: any){
 // Oracle: it reads draft labels. It is NOT an implementable retrieval policy.
 const refs=c.references.slice(0,5),need=c.facts.filter((f: any)=>f.role==='required');let best=null;
 for(let mask=1;mask<(1<<refs.length);mask++){
  const subset=refs.filter((_: any,i: any)=>mask&(1<<i));
  if(best&&subset.length>=best.length)continue;
  if(need.every((f: any)=>hasFact(subset,f)))best=subset;
 }
 return best?measureSelection(c,best):null;
}
export function evaluateFixture(input: any){
 const fixture=validateFixture(input),policies=['baseline','same_page_containment','topic_representatives','prefer_direct_headings'];
 const cases=fixture.cases.map((c: any)=>({id:c.id,split:c.split,description:c.description,
  policies:Object.fromEntries(policies.map(p=>[p,measureSelection(c,shadowSelection(c,p))])),labelledLowerBound:labelledLowerBound(c)}));
 const aggregate=(split: any)=>Object.fromEntries(policies.map(policy=>{
  const rows=cases.filter((c: any)=>c.split===split).map((c: any)=>c.policies[policy]);const sum=(key: any)=>rows.reduce((n: any,r: any)=>n+r[key],0);
  return [policy,{cases:rows.length,requiredFacts:sum('requiredFacts'),totalRequiredFacts:sum('totalRequiredFacts'),
   fullyCoveredCases:rows.filter((r: any)=>r.missingRequired.length===0).length,protectedRequiredFactLossCases:rows.filter((r: any)=>r.protectedRequiredMissing.length).length,
   references:sum('referenceCount'),distinctSourcesSummed:sum('distinctSources'),textCharacters:sum('textCharacters'),supportingFacts:sum('supportingFacts'),offIntentFacts:sum('offIntentFacts')}];
 }));
 return {schemaVersion:1,labelStatus:fixture.labelStatus,labelNotes:fixture.labelNotes,method:'Offline fixed-reference shadow comparison. No product path/model calls. Oracle uses labels; not a deployable policy. Supporting references are not counted as erroneous citations.',
  dev:aggregate('dev'),holdout:aggregate('holdout'),cases};
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
 const fixture=JSON.parse(await readFile(new URL('./citation-intent-fixture.json',import.meta.url),'utf8') as any);const report=evaluateFixture(fixture);
 if(process.argv[2])await writeFile(process.argv[2],JSON.stringify(report,null,2)+'\n');
 console.log(JSON.stringify({labelStatus:report.labelStatus,dev:report.dev,holdout:report.holdout},null,2));
}
