// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
// Evaluation-only revision. v1 questions and original tags stay untouched.
import {questionTaskFixture} from './question-task-fixture.ts';
const span=(q: any,reference: any)=>{
 const text=typeof reference==='string'?reference:reference.text;
 const occurrence=typeof reference==='string'?0:reference.occurrence;
 let start=-1;for(let i=0;i<=occurrence;i++) {start=q.indexOf(text,start+1);if(start<0)throw Error('oracle_span_missing');}
 return {start,end:start+text.length,text};
};
export function taskPlanOracleV2() {
 const definitions=[
  ['task-fees',[
   [['value'],'一般料金',[],[],['いくら']],
   [['value'],'学生料金',[],[],['いくら']],
   [['conditions'],'対象条件',[{text:'学生料金',occurrence:1}],[],['教えてください']],
  ]],
  ['task-delivery',[
   [['compare'],'到着日数',['配送X','配送Y'],[],['比較']],
   [['recommend'],'どちらを選べるか',['配送X','配送Y'],['急ぐ場合'],['どちらを選べるか']],
  ]],
  ['task-calculation',[
   [['calculate'],'合計金額',['教材A'],['税抜'],['計算']],
   [['value','calculate'],'最終支払額',['教材A'],['送料も含めた'],['いくら']],
  ]],
  ['task-exceptions',[
   [['value'],'返却期限',[],['通常'],['教えてください']],
   [['conditions'],'延長できる条件',[],[],['教えてください']],
   [['conditions'],'例外',[],['職員が返却日を変更した場合'],['教えてください']],
  ]],
  ['task-learning',[
   [['explain'],'密度の式',[],[],['説明']],
   [['explain'],'各記号の意味',[],[],['説明']],
   [['explain'],'体積と質量の関係',[],['初心者向け'],['解説']],
  ]],
  ['task-conflicting_summary',[
   [['summarize'],'利用規則',['案内A','案内B'],[],['要約']],
   [['compare'],'矛盾している点',['案内A','案内B'],[],['比較']],
   [['compare'],'一致している点',['案内A','案内B'],[],['比較']],
  ]],
 ];
 const questions=questionTaskFixture().cases;
 return {version:2,taxonomy:'task-plan-v2-20261015',syntheticOnly:true,humanReview:'pending',cases:definitions.map(([id,items])=>{
  const question=questions.find(q=>q.id===id).question;
  return {id,question,requirements:items.map(([allowedOperations,attribute,subjects,conditions,requests]: any,i: any)=>({
   id:'r'+(i+1),allowedOperations,interpretation:allowedOperations.length>1?'ambiguous':'declared',attribute:span(question,attribute),
   subjects:subjects.map((x: any)=>span(question,x)),conditions:conditions.map((x: any)=>span(question,x)),requestSpans:requests.map((x: any)=>span(question,x)),
  }))};
 })};
}
