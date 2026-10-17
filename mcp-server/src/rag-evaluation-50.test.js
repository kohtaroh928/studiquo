import test from 'node:test';
import assert from 'node:assert/strict';
import {loadEvaluation50,validateEvaluation50,buildEvaluation50Plan,answerProbeInput} from '../scripts/rag-quality/evaluation-50.mjs';
import {learningPairs} from '../scripts/rag-quality/learning-fixture.mjs';

test('50 new synthetic questions have valid exact evidence and 30/20 partition',()=>{
 const bank=loadEvaluation50();
 assert.equal(bank.cases.length,50);
 for(const c of bank.cases)assert.ok(!learningPairs.some(p=>p.query===c.question));
 for(const category of bank.categories)assert.equal(bank.cases.filter(c=>c.category===category).length,5);
 assert.equal(bank.cases.filter(c=>c.split==='development').length,30);
 assert.equal(bank.cases.filter(c=>c.split==='reserved_holdout').length,20);
 assert.equal(bank.humanGoldReview,'pending');
 assert.match(bank.holdoutPolicy,/not independently blind/);
});

test('validator rejects duplicate questions missing evidence invalid spans and partition drift',()=>{
 for(const mutate of [b=>b.cases.pop(),b=>b.cases[1].id=b.cases[0].id,b=>b.cases[1].question=b.cases[0].question,b=>b.cases[0].claims[0].evidence=[],b=>b.cases[0].claims[0].evidence[0].pageNumber=99,b=>b.cases[0].claims[0].evidence[0].quote='absent fragment',b=>b.cases[0].split='reserved_holdout',b=>b.cases[0].history=[{role:'system',text:'bad'}],b=>b.cases[0].claims[0].dimension='unknown',b=>b.syntheticOnly=false]) {
  const bank=loadEvaluation50();mutate(bank);assert.throws(()=>validateEvaluation50(bank),/invalid_evaluation_50/);
 }
});

test('offline plan has 100 pending scorecards in bounded paired stages and alternating style order',()=>{
 const plan=buildEvaluation50Plan();
 assert.equal(plan.networkCalls,0);assert.equal(plan.liveExecutionReady,false);
 assert.equal(plan.rows.length,100);assert.equal(plan.stages.length,17);
 assert.equal(plan.stages.reduce((n,s)=>n+s.plannedDispatches,0),100);
 assert.ok(plan.stages.every(s=>s.plannedDispatches<=6));
 assert.equal(plan.rows.filter(r=>r.split==='development').length,60);
 assert.equal(plan.rows.filter(r=>r.split==='reserved_holdout').length,40);
 for(let i=0;i<100;i+=2) {
  const [a,b]=plan.rows.slice(i,i+2);
  assert.equal(a.caseId,b.caseId);assert.equal(a.inputHash,b.inputHash);
  assert.notEqual(a.style,b.style);
  for(const row of [a,b])assert.ok(row.status==='pending'&&row.criteria.every(c=>c.result==='pending')&&row.forbiddenClaims.every(c=>c.result==='pending'));
 }
 assert.equal(plan.rows.filter((_,i)=>i%2===0&&plan.rows[i].style==='explain').length,25);
 assert.equal(plan.bankHash,buildEvaluation50Plan().bankHash);
});

test('answer input excludes gold and rubric; scorecard mutations never modify bank or paired inputs',()=>{
 const bank=loadEvaluation50(),before=JSON.stringify(bank);
 for(const c of bank.cases)assert.deepEqual(Object.keys(answerProbeInput(c)),['question','history','references']);
 const plan=buildEvaluation50Plan(bank),oldHash=plan.bankHash;
 plan.rows[0].criteria[0].evidence[0].quote='changed';
 assert.equal(JSON.stringify(bank),before);
 const edited=structuredClone(bank);edited.cases[0].claims[0].expected+=' review change';
 assert.notEqual(buildEvaluation50Plan(edited).bankHash,oldHash);
 assert.deepEqual(answerProbeInput(bank.cases[0]),answerProbeInput(edited.cases[0]));
});

test('gold comparison requires rectangular area and retains known height alongside unknown height',()=>{
 const c=loadEvaluation50().cases.find(c=>c.id==='e50-partial-02');
 assert.match(c.question,/天板面積/);
 assert.match(c.pages[0].text,/どちらも長方形/);
 assert.match(c.claims[0].expected,/P4000\/Q4500cm²/);
 assert.match(c.claims[1].expected,/Pの高さ70cm、Q高さ未確認/);
 for(const claim of c.claims)assert.ok(claim.evidence.some(e=>e.quote.includes('高さ70 cm')));
});
