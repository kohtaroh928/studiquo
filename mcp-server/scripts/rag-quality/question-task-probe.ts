// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
// Evaluation-only operation cues. No gold, source contents, keys or network.
import {questionTaskFixture} from './question-task-fixture.ts';
const rules=[
 ['lookup',/いくら|いつ|何日|何個|一覧/gu],
 ['compare',/比較|比べ/gu],
 ['recommend',/おすすめ|どちらを選|どれを選/gu],
 ['calculate',/計算|算出/gu],
 ['explain',/説明|解説/gu],
 ['conditions',/条件|例外/gu],
 ['summarize',/要約|まとめて/gu],
];

export function questionTaskProbe(question: any) {
 if(typeof question!=='string'||Buffer.byteLength(question)>16384)throw Error('invalid_task_question');
 const base={version:1,authoritative:false,evidenceSupport:'unknown',entities:'pending',attributes:'pending'};
 if(!question.trim())return {...base,status:'needs_review',reason:'empty',candidates:[]};
 if(/[「」『』`]|system\s*:|role\s*:|無視して|命令|不要|しない|しなくて|(?:^|[。\s])(?:それ|これ|あれ)/u.test(question))return {...base,status:'needs_review',reason:'ambiguous_or_nonpositive',candidates:[]};
 const candidates=[];
 for(const [operation,pattern] of rules)for(const m of question.matchAll(pattern)) {
  candidates.push({operation,questionSpan:{start:m.index,end:m.index+m[0].length,text:m[0]}});
 }
 candidates.sort((a,b)=>a.questionSpan.start-b.questionSpan.start);
 return {...base,status:candidates.length?'candidates':'needs_review',reason:candidates.length?'finite_cues':'unrecognized',candidates};
}

export function evaluateQuestionTaskFixture() {
 const fixture=questionTaskFixture();
 return {version:1,syntheticOnly:true,externalCalls:0,humanReview:fixture.humanReview,
  method:'operation-set diagnostic only; repeated attributes and entity binding remain pending',
  rows:fixture.cases.map(c=>{
   const probe=questionTaskProbe(c.question),expected=[...new Set(c.requirements.map((r: any)=>r.operation))],found=[...new Set(probe.candidates.map(r=>r.operation))];
   return {id:c.id,requiredAtomicItems:c.requirements.length,expectedOperations:expected,foundOperations:found,
    missingOperations:expected.filter(x=>!found.includes(x)),extraOperations:found.filter(x=>!expected.includes(x)),
    atomicExtraction:'pending',evidenceSupport:probe.evidenceSupport,releaseAccepted:false};
  })};
}
