// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {resolveQuotedTaskPlanV3 as resolve,taskPlanSchemaV3} from '../scripts/rag-quality/task-plan-quoted-v3.ts';
import {validateTaskPlanV2,taskPlanSchemaV2} from '../scripts/rag-quality/task-plan-v2.ts';
const q=(text,prefix='',suffix='')=>({text,prefix,suffix});
const task=(attribute=q('定員'),subjects=[q('展示室P')])=>({id:'t1',operation:'value',attribute,subjects,conditions:[],requestSpans:[q('何人')],resolution:'unknown',evidenceSupport:'unknown',comparisonPermission:'unknown'});
const plan=(t=task())=>({version:3,status:'candidate',tasks:[t],unresolved:[]});
const question='展示室Pの定員は何人ですか。';
const rejects=(question,p,code)=>assert.throws(()=>resolve(question,p),e=>e.message==='quoted_task_plan_'+code);
test('unique Japanese quote becomes server UTF16 positions without task or role changes',()=>{
 const input=plan(),before=structuredClone(input),r=resolve(question,input),p=r.resolvedPlan;
 assert.deepEqual(p.tasks[0].attribute,{start:5,end:7,text:'定員'});assert.deepEqual(p.tasks[0].subjects,[{start:0,end:4,text:'展示室P'}]);
 assert.deepEqual(validateTaskPlanV2(question,p),p);assert.deepEqual(input,before);assert.equal(r.semanticCompleteness,'pending');assert.equal(r.releaseAccepted,false);
 p.tasks[0].attribute.text='changed';assert.deepEqual(input,before);
});
test('repeated quotes require exact adjacent context; one-sided context can disambiguate',()=>{
 const text='展示室Pの定員と展示室Qの定員は何人ですか。';
 rejects(text,plan(),'quote_ambiguous');
 const a=plan(task(q('定員','展示室Qの')));assert.equal(resolve(text,a).resolvedPlan.tasks[0].attribute.start,13);
 const b=plan(task(q('定員','','と展示室Q')));assert.equal(resolve(text,b).resolvedPlan.tasks[0].attribute.start,5);
 rejects(text,plan(task(q('定員','存在しない'))),'quote_not_found');
 rejects(question,plan(task(q('定員','P','は'))),'quote_not_found');
});
test('overlapping matches are included rather than accepting the first match',()=>{
 const t=task(q('ああ'),[]);t.requestSpans=[q('何人')];
 rejects('あああ何人',plan(t),'quote_ambiguous');
 t.attribute=q('ああ','','何人');assert.equal(resolve('あああ何人',plan(t)).resolvedPlan.tasks[0].attribute.start,1);
});
test('emoji positions use UTF16 and split or lone surrogates are rejected',()=>{
 assert.equal(resolve('😀'+question,plan()).resolvedPlan.tasks[0].attribute.start,7);
 const t=task(q('😀'),[]);assert.deepEqual(resolve('😀何人',plan(t)).resolvedPlan.tasks[0].attribute,{start:0,end:2,text:'😀'});
 t.attribute=q('\ud83d');rejects('😀何人',plan(t),'quote_shape');t.attribute=q('何人','\ude00');rejects('😀何人',plan(t),'quote_shape');
 rejects('\ud83d'+question,plan(),'question');
});
test('combining marks ZWJ whitespace and full-width forms are exact and never normalized',()=>{
 const t=task(q('e\u0301'),[]);assert.equal(resolve('e\u0301何人',plan(t)).resolvedPlan.tasks.length,1);
 t.attribute=q('é');rejects('e\u0301何人',plan(t),'quote_not_found');
 t.attribute=q('👩\u200d💻');assert.equal(resolve('👩\u200d💻何人',plan(t)).resolvedPlan.tasks[0].attribute.end,5);
 t.attribute=q('A');rejects('Ａ何人',plan(t),'quote_not_found');
 t.attribute=q('定員','\n','\r\n');assert.equal(resolve('表\n定員\r\n何人',plan(t)).resolvedPlan.tasks[0].attribute.start,2);
 t.attribute=q('定員',' ','\n');rejects('表\n定員\r\n何人',plan(t),'quote_not_found');
});
test('v3 fields are exact and never accept rejected v2 offsets as an implicit fallback',()=>{
 const p=plan();p.tasks[0].attribute.start=5;rejects(question,p,'quote_shape');
 p.tasks[0].attribute=q('定員');p.version=2;rejects(question,p,'shape');
 const old={version:2,status:'candidate',tasks:[{...task(),attribute:{start:4,end:6,text:'定員'}}],unresolved:[]};rejects(question,old,'shape');
 p.version=3;p.extra=0;rejects(question,p,'shape');
});
test('forged support duplicate spans ids and root status inconsistency remain rejected by contract',()=>{
 for(const field of ['resolution','evidenceSupport','comparisonPermission']){const p=plan();p.tasks[0][field]='allowed';rejects(question,p,'invalid_plan');}
 const p=plan();p.tasks[0].subjects=[q('展示室P'),q('展示室P','','の')];rejects(question,p,'invalid_plan');
 const d=plan();d.tasks.push(structuredClone(d.tasks[0]));rejects(question,d,'invalid_plan');
 const c=plan();c.status='needs_clarification';rejects(question,c,'invalid_plan');
 c.unresolved=[{kind:'reference',span:q('展示室P')}];assert.equal(resolve(question,c).resolvedPlan.status,'needs_clarification');
});
test('question plan quote and collection bounds fail closed including maximum question',()=>{
 rejects('あ'.repeat(5462),plan(),'question');
 const t=task(q('定員','あ'.repeat(129)),[]);rejects(question,plan(t),'quote_shape');
 t.attribute=q('a'.repeat(4097));rejects('a'.repeat(4097)+'何人',plan(t),'quote_shape');
 const p=plan();p.tasks=Array.from({length:17},()=>task());rejects(question,p,'shape');
 const l=plan();l.tasks[0].subjects=Array(5).fill(q('展示室P'));rejects(question,l,'shape');
 const b=plan();b.tasks[0].conditions=Array(4).fill(q('a'.repeat(4096)));b.tasks[0].subjects=Array(4).fill(q('b'.repeat(4096)));rejects(question,b,'input');
 const max='a'.repeat(16384-Buffer.byteLength(question))+question;assert.equal(Buffer.byteLength(max),16384);assert.equal(resolve(max,plan()).resolvedPlan.tasks.length,1);
});
test('non JSON values accessors sparse arrays symbols cycles and special objects never leak errors',()=>{
 const cases=[undefined,NaN,Infinity,new Date(),()=>{},new Map()];for(const value of cases){const p=plan();p.extra=value;rejects(question,p,'input');}
 const cycle=plan();cycle.self=cycle;rejects(question,cycle,'input');
 const sparse=plan();sparse.tasks=Array(1);rejects(question,sparse,'input');
 const accessor=plan();Object.defineProperty(accessor,'status',{get(){throw Error('synthetic_private');},enumerable:true});rejects(question,accessor,'input');
 const symbol=plan();symbol[Symbol('synthetic_private')]=0;rejects(question,symbol,'input');
 const proxy=new Proxy({},{ownKeys(){throw Error('synthetic_private');}});rejects(question,proxy,'input');
});
test('schema uses quote objects everywhere and returned instances cannot mutate v2 or each other',()=>{
 const before=taskPlanSchemaV2(),s=taskPlanSchemaV3();assert.equal(s.properties.version.const,3);
 for(const schema of [s.properties.tasks.items.properties.attribute,...['subjects','conditions','requestSpans'].map(n=>s.properties.tasks.items.properties[n].items),s.properties.unresolved.items.properties.span])assert.deepEqual(schema.required,['text','prefix','suffix']);
 s.properties.tasks.items.properties.attribute.properties.text.maxLength=1;
 assert.equal(taskPlanSchemaV3().properties.tasks.items.properties.attribute.properties.text.maxLength,4096);assert.deepEqual(taskPlanSchemaV2(),before);
 assert.throws(()=>taskPlanSchemaV3({}));assert.throws(()=>resolve(question,plan(),{}));
});
test('exact provenance does not pretend to verify semantic role correctness',()=>{
 const t=task(q('展示室P'),[q('定員')]);const r=resolve(question,plan(t));assert.equal(r.semanticCompleteness,'pending');assert.equal(r.evidenceSupport,'unknown');assert.equal(r.releaseAccepted,false);
});

test('thirteen existing development oracle scopes round-trip without modifying annotations or using held-out cases',()=>{
 const oracle=JSON.parse(readFileSync(new URL('../scripts/rag-quality/task-plan-paired-oracle-v1.json',import.meta.url)));let scopes=0;
 for(const c of oracle.cases){
  const quoted=span=>q(span.text,c.question.slice(Math.max(0,span.start-128),span.start),c.question.slice(span.end,span.end+128));
  const tasks=c.requirements.map((r,i)=>({id:'t'+(i+1),operation:r.allowedOperations[0],attribute:quoted(r.attribute),subjects:r.subjects.map(quoted),conditions:r.conditions.map(quoted),requestSpans:r.requestSpans.map(quoted),resolution:'unknown',evidenceSupport:'unknown',comparisonPermission:'unknown'}));
  const result=resolve(c.question,{version:3,status:'candidate',tasks,unresolved:[]});
  c.requirements.forEach((r,i)=>{const t=result.resolvedPlan.tasks[i];for(const name of ['attribute','subjects','conditions','requestSpans'])assert.deepEqual(t[name],r[name]);});scopes+=tasks.length;
 }
 assert.equal(oracle.cases.length,8);assert.equal(scopes,13);
});

test('even hostile thrown proxies cannot escape fixed errors through exception inspection',()=>{
 const thrown=new Proxy({},{getPrototypeOf(){throw Error('synthetic_private_detail');},get(){throw Error('synthetic_private_detail');}});
 const input=new Proxy({},{ownKeys(){throw thrown;}});rejects(question,input,'input');
});
