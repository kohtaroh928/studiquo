import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {subjectRoleTaskPlannerRequest as request,subjectRoleTaskPlannerManifest as manifest} from '../scripts/rag-quality/subject-role-task-planner-request.mjs';
import {unitTaskPlannerRequest} from '../scripts/rag-quality/unit-task-planner-request.mjs';
import {createQuestionUnits} from '../scripts/rag-quality/question-units.mjs';
const raw=readFileSync(new URL('../scripts/rag-quality/role-preservation-questions-v1.json',import.meta.url)),questions=JSON.parse(raw).cases;
const hash=x=>createHash('sha256').update(x).digest('hex');
test('paired policies change only generic subject instructions with identical new question settings and schema',()=>{
 const parent=unitTaskPlannerRequest(0);for(let i=0;i<12;i++){
  const b=request(i,'baseline'),c=request(i,'candidate');assert.deepEqual({...b,instructions:null},{...c,instructions:null});assert.equal(b.instructions,parent.instructions);assert.ok(c.instructions.startsWith(b.instructions+'\nAdditional subject-role preservation rules:'));assert.match(c.instructions,/leave subjects empty/);assert.match(c.instructions,/not a substitute/);
  assert.deepEqual({...b,input:null,text:null},{...parent,input:null,text:null});assert.deepEqual(b.reasoning,{effort:'medium'});assert.equal(b.store,false);assert.equal(b.max_output_tokens,8192);
  const source=createQuestionUnits(questions[i].question);assert.deepEqual(JSON.parse(b.input[0].content[0].text),{question:questions[i].question,questionHash:source.questionHash,units:source.units.map(({id,text})=>({id,text}))});
  assert.deepEqual(b.text.format.schema.properties.questionHash.enum,[source.questionHash]);assert.deepEqual(b.text.format.schema.properties.tasks.items.properties.attribute.properties.unitIds.items.enum,source.units.map(u=>u.id));assert.equal(b.text.format.strict,true);
  const inspect=o=>{if(!o||typeof o!=='object')return;if(o.type==='object'){assert.equal(o.additionalProperties,false);assert.deepEqual([...o.required].sort(),Object.keys(o.properties).sort());}Object.values(o).forEach(inspect);};inspect(b.text.format.schema);
 }
});
test('manifest binds all 24 fixed request variants without embedding original question text',()=>{
 const m=manifest();assert.equal(m.questionCount,12);assert.equal(m.rows.length,24);assert.equal(m.questionFileHash,hash(raw));assert.equal(m.parentReferenceRequestHash,hash(JSON.stringify(unitTaskPlannerRequest(0))));assert.equal(m.contractVersion,4);assert.equal(m.modelEvaluated,false);assert.equal(m.externalCalls,0);
 for(const row of m.rows){const b=request(row.index,row.variant);assert.equal(row.requestHash,hash(JSON.stringify(b)));assert.equal(row.schemaHash,hash(JSON.stringify(b.text.format.schema)));assert.equal(row.instructionsHash,hash(b.instructions));assert.equal(row.bytes,Buffer.byteLength(JSON.stringify(b)));assert.ok(row.bytes<=32768);}
 assert.equal(JSON.stringify(m).includes(questions[0].question),false);
});
test('selectors reject overrides and all snapshots remain isolated',()=>{
 for(const i of [-1,12,'0',null,undefined])assert.throws(()=>request(i,'candidate'));for(const v of ['',null,'other',{}])assert.throws(()=>request(0,v));assert.throws(()=>request(0,'baseline',{}));assert.throws(()=>manifest({}));
 const before=JSON.stringify(request(0,'candidate')),c=request(0,'candidate');c.instructions='changed';c.text.format.schema.properties.questionHash.enum[0]='bad';assert.equal(JSON.stringify(request(0,'candidate')),before);const m=manifest();m.rows[0].requestHash='bad';assert.notEqual(manifest().rows[0].requestHash,'bad');
});
