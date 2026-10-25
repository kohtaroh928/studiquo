// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import {readFile,writeFile} from 'node:fs/promises';
import {performance} from 'node:perf_hooks';
import {queryPlan} from '../../src/rag/query.ts';
import {detailRequirements,assessReferences} from '../../src/rag/answerability.ts';
import {selectEvidence} from '../../src/rag/evidence-selection.ts';
export function evaluateFixture(fixture: any){
 const rows=fixture.cases.map((c: any)=>{
  const plan=queryPlan(c.question),requirements=detailRequirements(c.question,plan.coverageGroups);
  const refs=c.candidates.map((r: any)=>({citation:{sourceId:r.sourceId??'synthetic-'+c.id,title:'合成評価資料',pageNumber:r.page,chunkId:c.id+'-'+r.page},text:r.text}));
  const measure=(selector: any)=>{
   const start=performance.now(),selected=selector(),elapsedMs=performance.now()-start;
   const combined=selected.map((r: any)=>r.text).join('\n');
   // Labels are fixture annotations, deliberately independent of the parser.
   const found=c.requiredFacts.filter((f: any)=>combined.includes(f));
   const unique=new Set(selected.map((r: any)=>JSON.stringify([r.citation.sourceId,r.text])));
   const decision=assessReferences(selected,requirements);
   return {pages:selected.map((r: any)=>r.citation.pageNumber),requiredFacts:found.length,totalFacts:c.requiredFacts.length,
    selectorCitationPrecision:selected.length?selected.filter((r: any)=>c.acceptablePages.includes(r.citation.pageNumber)).length/selected.length:null,
    duplicateReferences:selected.length-unique.size,selectorContextCharacters:selected.reduce((s: any,r: any)=>s+r.text.length,0),
    detailGateAccepted:decision.accepted,selectionMs:elapsedMs,additionalModelCalls:0};
  };
  return {id:c.id,split:c.split,before:measure(()=>refs.slice(0,5)),after:measure(()=>selectEvidence(refs,plan,requirements))};
 });
 const aggregate=(split: any)=>{
  const subset=rows.filter((r: any)=>r.split===split);
  return Object.fromEntries(['before','after'].map(side=>{
   const vals=subset.map((r: any)=>r[side]),sum=(key: any)=>vals.reduce((s: any,v: any)=>s+v[key],0);
   return [side,{cases:vals.length,factCoverage:sum('requiredFacts')/sum('totalFacts'),fullyCoveredCases:vals.filter((v: any)=>v.requiredFacts===v.totalFacts).length,
    meanSelectorCitationPrecision:vals.reduce((s: any,v: any)=>s+(v.selectorCitationPrecision??0),0)/vals.length,duplicateReferences:sum('duplicateReferences'),
    selectorContextCharacters:sum('selectorContextCharacters'),detailGateAcceptedCases:vals.filter((v: any)=>v.detailGateAccepted).length,
    localSelectionMs:sum('selectionMs'),additionalModelCalls:0}];
  }));
 };
 return {schemaVersion:1,labelStatus:fixture.labelStatus,method:'Local selector replay with fixed ranked candidates; reserves assumed authorized. Not a retrieval, Gemini answer, Cloudflare latency or billing evaluation.',
  dev:aggregate('dev'),holdout:aggregate('holdout'),cases:rows};
}
if(process.argv[1]&&import.meta.url===new URL('file://'+process.argv[1]).href){
 const fixture=JSON.parse(await readFile(new URL('./evidence-selection-fixture.json',import.meta.url),'utf8') as any);
 const result=evaluateFixture(fixture);
 if(process.argv[2])await writeFile(process.argv[2],JSON.stringify(result,null,2)+'\n');
 console.log(JSON.stringify({labelStatus:result.labelStatus,dev:result.dev,holdout:result.holdout},null,2));
}
