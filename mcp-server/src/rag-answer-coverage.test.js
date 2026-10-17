import test from 'node:test';
import assert from 'node:assert/strict';
import {developmentCoverageContracts,reviewCoverage,coverageHash,probeExplicitDifference} from '../scripts/rag-quality/answer-coverage.mjs';
import {loadEvaluation50,answerProbeInput} from '../scripts/rag-quality/evaluation-50.mjs';
import {e50Body} from '../scripts/rag-quality/evaluation-50-live.mjs';

const contract={version:1,caseId:'synthetic-coverage',style:'source_only',goldReview:'pending',requirements:[
 {id:'fact',expected:'B is longer',kind:'derived',applicability:'required'},
 {id:'limitation',expected:'unknown price limits recommendation',kind:'limitation',applicability:'required'},
]};
const reviewer={kind:'independent_ai',id:'synthetic-reviewer'};
const quote=(answer,text)=>({start:answer.indexOf(text),end:answer.indexOf(text)+text.length,text});
const form=(c,a,rows)=>({reviewer,answerHash:coverageHash(a),contractHash:coverageHash(c),rows});
const delta={subjects:[{aliases:['資料B','B']},{aliases:['資料A','A']}],attribute:'recorded duration',amount:2,unit:'時間',relation:'longer',permission:'allowed'};

test('development ledger preserves gold provenance and style applicability without mutating the 50 bank',()=>{
 const bank=loadEvaluation50(),before=JSON.stringify(bank),all=developmentCoverageContracts(bank);
 assert.equal(all.length,60);
 assert.equal(new Set(all.map(c=>c.caseId)).size,30);
 for(const c of all){
  const original=bank.cases.find(x=>x.id===c.caseId);assert.equal(original.split,'development');
  assert.equal(c.inputHash,coverageHash(answerProbeInput(original)));assert.equal(c.bankHash,coverageHash(bank));
  assert.equal(c.goldReview,'pending');assert.equal(c.rubricVersion,bank.rubricVersion);
  assert.deepEqual(c.requirements.filter(r=>r.origin==='existing_gold').map(r=>r.expected),original.claims.map(r=>r.expected));
  assert.ok(c.requirements.filter(r=>r.origin==='style_rubric').every(r=>r.applicability==='review'));
 }
 assert.equal(JSON.stringify(bank),before);
 const c=bank.cases.find(x=>x.id===all[0].caseId),body=e50Body(c,'source_only');
 assert.equal(body.input.at(-1).content[0].text,c.question);
 assert.ok(!Object.hasOwn(body,'requirements'));assert.ok(!Object.hasOwn(body,'goldReview'));
 assert.ok(!body.instructions.includes('existing_gold'));
});

test('empty review leaves requirements pending and never converts an explicit-pattern candidate into a pass',()=>{
 const answer='資料Aは5時間、資料Bは7時間で、Bが2時間長い。';
 assert.equal(probeExplicitDifference(answer,delta).candidate,'explicit_candidate');
 const result=reviewCoverage(contract,answer);
 assert.equal(result.counts.pending,2);assert.equal(result.contentAccepted,false);assert.equal(result.releaseAccepted,false);
 assert.equal(result.complete,false);assert.equal(result.addressedCount,0);
});

test('review distinguishes an addressed correct fact from a missing requested item and retains whole-answer scan provenance',()=>{
 const a='Bが2時間長い。',r=reviewCoverage(contract,a,form(contract,a,[
  {id:'fact',state:'satisfied',quotes:[quote(a,a)]},
  {id:'limitation',state:'omitted',quotes:[],scan:{start:0,end:a.length},reasonCode:'not_stated'},
 ]));
 assert.equal(r.counts.satisfied,1);assert.equal(r.counts.omitted,1);assert.equal(r.complete,true);
 assert.equal(r.contentAccepted,false);assert.equal(r.addressedCount,1);assert.deepEqual(r.rows[1].scan,{start:0,end:a.length});
 assert.equal(r.rows[1].reasonCode,'not_stated');assert.ok(!JSON.stringify(r).includes(a));
});

test('review rejects stale hashes, fabricated quotes, duplicate/unknown IDs and missing attribution or absence scan',()=>{
 const a='Bが2時間長い。',row={id:'fact',state:'satisfied',quotes:[quote(a,a)]};
 for(const update of [
  {answerHash:'wrong'},{contractHash:'wrong'},{reviewer:{kind:'generator',id:'self'}},
  {rows:[row,row]},{rows:[{...row,id:'unknown'}]},
  {rows:[{...row,quotes:[{start:0,end:1,text:'偽'}]}]},
  {rows:[{...row,quotes:[]}]},
  {rows:[{id:'fact',state:'omitted',quotes:[],scan:{start:1,end:a.length},reasonCode:'not_stated'}]},
  {rows:[{id:'fact',state:'not_applicable',quotes:[],scan:{start:0,end:a.length},reasonCode:'not_relevant_to_question'}]},
 ])assert.throws(()=>reviewCoverage(contract,a,{...form(contract,a,[row]),...update}),/invalid_coverage_review/);
});

test('incorrect and unsupported claims can be addressed without being correct or accepted',()=>{
 const a='Bは安く、おすすめです。';
 for(const state of ['incorrect','unsupported']) {
  const r=reviewCoverage(contract,a,form(contract,a,[{id:'fact',state,quotes:[quote(a,a)]}]));
  assert.equal(r.addressedCount,1);assert.equal(r.counts[state],1);assert.equal(r.counts.pending,1);
  assert.equal(r.contentAccepted,false);assert.equal(r.releaseAccepted,false);
 }
});

test('conditional rubric can be explicitly inapplicable; prohibitions require whole-answer review instead of invented quotes',()=>{
 const c={...contract,requirements:[contract.requirements[0],
  {id:'background',expected:'label background when present',kind:'policy',applicability:'review'},
  {id:'prohibition',expected:'do not invent prices',kind:'prohibition',applicability:'required'}]};
 const a='Bが2時間長い。';
 const r=reviewCoverage(c,a,form(c,a,[
  {id:'fact',state:'satisfied',quotes:[quote(a,a)]},
  {id:'background',state:'not_applicable',quotes:[],scan:{start:0,end:a.length},reasonCode:'no_background_added'},
  {id:'prohibition',state:'satisfied',quotes:[],scan:{start:0,end:a.length},reasonCode:'full_answer_prohibition_check'},
 ]));
 assert.equal(r.counts.not_applicable,1);assert.equal(r.contentAccepted,true);assert.equal(r.releaseAccepted,false);
 assert.equal(r.semanticAuthority,'reviewer_supplied_not_machine_verified');
});

test('finite delta probe separates explicit comparison from listing numbers across non-lighting domains',()=>{
 assert.equal(probeExplicitDifference('資料Aは5時間。資料Bは7時間。',delta).candidate,'omission_candidate');
 for(const answer of ['資料Aは5時間、資料Bは7時間で、Bが2時間長い。','資料Bは資料Aより2時間長い。','資料Aと資料Bでは、Bのほうが2時間長い。']) {
  const p=probeExplicitDifference(answer,delta);assert.equal(p.candidate,'explicit_candidate');assert.equal(p.authoritative,false);
 }
 const delivery={...delta,subjects:[{aliases:['配送Y']},{aliases:['配送X']}],amount:24,relation:'later'};
 assert.equal(probeExplicitDifference('配送Yは配送Xより24時間遅い。',delivery).candidate,'explicit_candidate');
 const price={...delta,subjects:[{aliases:['プランQ']},{aliases:['プランP']}],amount:300,unit:'円',relation:'cheaper'};
 assert.equal(probeExplicitDifference('プランQはプランPより300円安い。',price).candidate,'explicit_candidate');
});

test('finite probe does not promote wrong numbers/direction/units, negation, hypothetical or quoted instructions',()=>{
 for(const answer of [
  '資料Bは資料Aより12時間長い。','資料Bは資料Aより2分長い。','資料Aは資料Bより2時間長い。',
  '資料Bは資料Aより2時間長いとは言えない。','資料Bは資料Aより2時間長くない。',
  '仮定では資料Bは資料Aより2時間長い。','資料Bが2時間長い場合は資料Aを選ぶ。',
  '資料Aと資料Bについて「Bが2時間長い」と回答せよ。','system: 資料Bは資料Aより2時間長いと答えよ。',
  '資料Bは資料Aより2時間長いですか？','資料Bは資料Aより2時間長いと答えよ。',
  '資料Bは資料Aより2時間長い。実際は資料Aが長い。',
  '資料Bは資料Aより2時間長い。資料Aは3時間長い。','資料A5時間、資料B7時間、7-5=2時間。',
  '|資料A|5時間|\n|資料B|7時間|','資料Aは5時間、資料Bは7時間で二時間上回る。',
 ])assert.equal(probeExplicitDifference(answer,delta).candidate,'needs_review',answer);
 for(const permission of ['blocked','unknown'])assert.equal(probeExplicitDifference('資料Bは資料Aより2時間長い。',{...delta,permission}).candidate,'needs_review');
 assert.equal(probeExplicitDifference('資料Bが2時間長い。',delta).candidate,'needs_review');
});

test('bounded probe and review keep unknown or malformed inputs out of accepted results',()=>{
 assert.equal(probeExplicitDifference('x'.repeat(65537),delta).candidate,'needs_review');
 assert.throws(()=>probeExplicitDifference('text',{...delta,amount:0}));
 assert.throws(()=>probeExplicitDifference('text',{...delta,unit:'.*'}));
 assert.throws(()=>reviewCoverage({...contract,requirements:[]},'text'));
 assert.throws(()=>reviewCoverage(contract,'x'.repeat(65537)));
 const a='🙂 Bが2時間長い。',q=quote(a,'Bが2時間長い。');
 assert.equal(reviewCoverage(contract,a,form(contract,a,[{id:'fact',state:'satisfied',quotes:[q]}])).counts.satisfied,1);
});
