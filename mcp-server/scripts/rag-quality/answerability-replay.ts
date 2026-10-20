// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
// Offline replay of the NEW evidence gate on saved real-AI retrieval snapshots.
// This does not remeasure embedding, ranking, Vectorize or Gemini answers.
import fs from 'node:fs';
import { detailRequirements, assessReferences } from '../../src/rag/answerability.ts';
import { queryPlan } from '../../src/rag/query.ts';
import { chunkPage } from '../../src/rag/chunking.ts';
const extractedPath = process.argv[2];
const outputPath = process.argv[3];
if (!extractedPath || !outputPath) throw new Error('Provide synthetic extracted-pages.json and output path');
const pages = JSON.parse(fs.readFileSync(extractedPath));
if (pages.length !== 100) throw new Error('Expected 100 synthetic pages');
const chunks = new Map(pages.map((p: any) => {
 const children = chunkPage(p.text);
 if (children.length !== 1) throw new Error('This snapshot requires one child per synthetic page');
 return [p.pageNumber, children[0]];
}));
const sets = [];
for (const [fixture, result] of [['fixture','RESULTS'],['holdout-fixture','HOLDOUT'],['validation-fixture','VALIDATION']]) {
 const questions = JSON.parse(fs.readFileSync(new URL(`./${fixture}.json`,import.meta.url) as any) as any).queries;
 const baseline = JSON.parse(fs.readFileSync(new URL(`../../../docs/RAG_SEARCH_QUALITY_V2_${result}.json`,import.meta.url) as any) as any);
 const rows = questions.map((q: any) => {
  const old = baseline.results.find((r: any)=>r.id===q.id);
  const plan = queryPlan(q.query,q.previousQuestion);
  const requirements = detailRequirements(plan.canonicalQuery,plan.coverageGroups);
  const refs = old.stages.final.map((pageNumber: any)=>({citation:{pageNumber},text:chunks.get(pageNumber).slice(0,6000)}));
  const decision = assessReferences(refs,requirements);
  const after = decision.references.map((r: any)=>r.citation.pageNumber);
  return {id:q.id,kind:q.kind,expectedPages:q.expectedPages,before:old.stages.final,after,
   beforeAllExpected:q.expectedPages.length>0 && q.expectedPages.every((n: any)=>old.stages.final.includes(n)),
   afterAllExpected:q.expectedPages.length>0 && q.expectedPages.every((n: any)=>after.includes(n)),
   gateApplied:requirements.facets.length>0};
 });
 sets.push({set:fixture,count:rows.length,
  positives:rows.filter((r: any)=>r.expectedPages.length).length,
  beforeAllExpected:rows.filter((r: any)=>r.beforeAllExpected).length,
  afterAllExpected:rows.filter((r: any)=>r.afterAllExpected).length,
  negativeBeforeWithReferences:rows.filter((r: any)=>!r.expectedPages.length && r.before.length).length,
  negativeAfterWithReferences:rows.filter((r: any)=>!r.expectedPages.length && r.after.length).length,rows});
}
fs.writeFileSync(outputPath,JSON.stringify({method:'offline evidence-gate replay of saved retrieval pages; no new AI calls or final-answer evaluation',pages:100,sets},null,2));
console.log(JSON.stringify(sets.map(({rows,...summary})=>summary)));
