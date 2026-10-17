import test from 'node:test';
import assert from 'node:assert/strict';
import {explicitOldRuleDiagnostic} from '../scripts/rag-quality/evaluation-50-explicit-rule.mjs';
import {loadEvaluation50,validateEvaluation50,buildEvaluation50Plan} from '../scripts/rag-quality/evaluation-50.mjs';
import {e50Body,e50Manifest} from '../scripts/rag-quality/evaluation-50-live.mjs';

test('explicit diagnostic changes only the rule evidence in a separate suite, preserving original questions and gold',()=>{
 const original=loadEvaluation50(),before=JSON.stringify(original),diagnostic=explicitOldRuleDiagnostic();
 validateEvaluation50(diagnostic);
 assert.notEqual(original.suiteId,diagnostic.suiteId);
 assert.notEqual(buildEvaluation50Plan(original).bankHash,buildEvaluation50Plan(diagnostic).bankHash);
 for(let i=0;i<50;i++) {
  const a=original.cases[i],b=diagnostic.cases[i];
  assert.equal(a.question,b.question);assert.deepEqual(a.claims,b.claims);
  if(a.id!=='e50-versions-03')assert.deepEqual(a,b);
  else assert.ok(b.pages[0].text.startsWith(a.pages[0].text));
 }
 assert.equal(JSON.stringify(loadEvaluation50()),before);
 const manifest=e50Manifest(diagnostic,['e50-versions-03']);
 assert.equal(manifest.jobs.length,2);
 assert.match(e50Body(diagnostic.cases.find(c=>c.id==='e50-versions-03'),'explain').instructions,/改訂前の同じ合成輸送便/);
});
