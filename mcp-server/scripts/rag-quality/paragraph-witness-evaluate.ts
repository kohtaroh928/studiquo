// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
// Offline labelled-span diagnostic. No provider calls or product integration.
import {readFile,writeFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
import {validateFixture,measureSelection} from './citation-intent-evaluate.ts';
import {paragraphTask} from './paragraph-proposal.ts';
const equal=(a: any,b: any)=>JSON.stringify(a)===JSON.stringify(b);
const overlaps=(p: any,e: any)=>p.referenceId===e.referenceId&&p.start<e.end&&e.start<p.end;
function covered(e: any,witnesses: any){
 let cursor=e.start;
 for(const p of witnesses.filter((p: any)=>p.referenceId===e.referenceId).sort((a: any,b: any)=>a.start-b.start)){
  if(p.end<=cursor)continue;
  if(p.start>cursor)return false;
  cursor=Math.max(cursor,p.end);if(cursor>=e.end)return true;
 }
 return false;
}
export function measureWitnesses(c: any,task: any,selectedReferences: any,witnesses: any){
 validateFixture({schemaVersion:1,cases:[c]});
 const canonical=paragraphTask(c.question,c.references.slice(0,5));
 if(!equal(task,canonical)||!Array.isArray(selectedReferences)||!Array.isArray(witnesses))throw Error('invalid_witness_input');
 const selected=new Set();
 for(const r of selectedReferences){
  if(selected.has(r?.id)||!equal(r,canonical.references.find(x=>x.id===r?.id)))throw Error('invalid_selected_reference');
  selected.add(r.id);
 }
 const seen=new Set();
 for(const p of witnesses){
  if(seen.has(p?.id)||!selected.has(p?.referenceId)||!equal(p,canonical.paragraphs.find(x=>x.id===p?.id)))throw Error('invalid_witness');
  seen.add(p.id);
 }
 const has=(f: any)=>f.evidence.some((e: any)=>covered(e,witnesses));
 const required=c.facts.filter((f: any)=>f.role==='required'),evidence=c.facts.flatMap((f: any)=>f.evidence);
 const missing=required.filter((f: any)=>!has(f));
 const unlabelled=witnesses.filter(p=>!evidence.some((e: any)=>overlaps(p,e)));
 const partial=witnesses.filter(p=>evidence.some((e: any)=>overlaps(p,e)&&!covered(e,[p])));
 return {method:'Exact draft-labelled original-span coverage; not semantic entailment or relevance accuracy.',witnessIds:witnesses.map(p=>p.id),witnessCount:witnesses.length,
  requiredFacts:required.length-missing.length,totalRequiredFacts:required.length,missingRequired:missing.map((f: any)=>f.id),protectedRequiredMissing:missing.filter((f: any)=>f.protected).map((f: any)=>f.id),
  supportingFacts:c.facts.filter((f: any)=>f.role==='supporting'&&has(f)).length,offIntentFacts:c.facts.filter((f: any)=>f.role==='off_intent'&&has(f)).length,
  unlabelledWitnessIds:unlabelled.map(p=>p.id),partialLabelOverlapWitnessIds:partial.map(p=>p.id),
  singleParagraphReferences:canonical.references.filter(r=>canonical.paragraphs.filter(p=>p.referenceId===r.id).length===1).length,totalReferences:canonical.references.length};
}
export function evaluateWitnessControls(fixture: any){
 validateFixture(fixture);
 const cases=fixture.cases.map((c: any)=>{
  const t=paragraphTask(c.question,c.references.slice(0,5));
  const first=t.references.map(r=>t.paragraphs.find(p=>p.referenceId===r.id));
  // Label-reading oracle is a diagnostic bound, never a model or deployable policy.
  const oracle=t.paragraphs.filter(p=>c.facts.filter((f: any)=>f.role==='required').some((f: any)=>f.evidence.some((e: any)=>overlaps(p,e))));
  return {id:c.id,split:c.split,fullReferences:measureSelection(c,t.references),firstParagraph:measureWitnesses(c,t,t.references,first),labelOracle:measureWitnesses(c,t,t.references,oracle)};
 });
 return {schemaVersion:1,labelStatus:fixture.labelStatus,method:'Offline deterministic controls, zero model calls. Oracle reads draft labels. Unlabelled witnesses are not classified as irrelevant. Whole-reference paragraphs limit discrimination.',
  summary:{cases:cases.length,singleParagraphReferences:cases.reduce((n: any,c: any)=>n+c.firstParagraph.singleParagraphReferences,0),totalReferences:cases.reduce((n: any,c: any)=>n+c.firstParagraph.totalReferences,0),fullReferenceCoveredCases:cases.filter((c: any)=>!c.fullReferences.missingRequired.length).length,firstParagraphMissingCases:cases.filter((c: any)=>c.firstParagraph.missingRequired.length).length,labelOracleMissingCases:cases.filter((c: any)=>c.labelOracle.missingRequired.length).length},cases};
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
 const f=JSON.parse(await readFile(new URL('./citation-intent-fixture.json',import.meta.url),'utf8') as any);
 const report=evaluateWitnessControls(f);if(process.argv[2])await writeFile(process.argv[2],JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report.summary));
}
