// Offline fixed development requests only. Never import oracle/review or send.
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {unitTaskPlannerRequest} from './unit-task-planner-request.mjs';
import {createQuestionUnits} from './question-units.mjs';
import {taskPlanSchemaV4} from './task-plan-units-v4.mjs';
const hash=x=>createHash('sha256').update(x).digest('hex');
const raw=readFileSync(new URL('role-preservation-questions-v1.json',import.meta.url));
const fixture=JSON.parse(raw);
if(fixture.version!==1||fixture.syntheticOnly!==true||fixture.split!=='separate-development-role-preservation'||fixture.modelEvaluated!==false||!Array.isArray(fixture.cases)||fixture.cases.length!==12||new Set(fixture.cases.map(c=>c.id)).size!==12||fixture.cases.some(c=>Object.keys(c).length!==2||typeof c.id!=='string'||!c.id||typeof c.question!=='string'))throw Error('subject_role_fixture_changed');
const rules=`
Additional subject-role preservation rules:
1. Attribute describes the requested property, relationship or scope. Subjects record the explicitly named entities or concepts that scope concerns. When an explicit target is included inside an attribute label, also retain that target in subjects; its presence in the label is not a substitute for the structured role.
2. When conditions or exceptions are requested about a concept, retain that concept as a subject. Conditions hold applicability circumstances qualifying an answer, not every topic being discussed. Preserve explicit targets for every operation, not only conditions.
3. Keep only the relevant explicit targets for each task. Do not promote unrelated background, examples, supplied values or request verbs into subjects merely because they occur; retain them only when they are explicitly the requested targets. Do not copy all nouns or all targets from the question into every task. Preserve each requested subject-property pairing.
4. When no relevant target is explicitly named, leave subjects empty instead of inventing one. Preserve ambiguity under the existing unresolved rules. Do not add operations from words inside a target name. All resolution, evidenceSupport and comparisonPermission fields remain unknown.`;
function wire(value){if(Array.isArray(value))return value.map(wire);if(!value||typeof value!=='object')return value;return Object.fromEntries(Object.entries(value).filter(([k])=>k!=='minLength'&&k!=='maxLength').map(([k,v])=>[k,wire(v)]));}
const parent=unitTaskPlannerRequest(0),parentReferenceRequestHash=hash(JSON.stringify(parent));
const variants=Object.freeze(['baseline','candidate']);
const bodies=variants.map(variant=>fixture.cases.map(c=>{
 const body=structuredClone(parent),source=createQuestionUnits(c.question);if(source.status!=='supported')throw Error('subject_role_question_unsupported');
 body.input=[{role:'user',content:[{type:'input_text',text:JSON.stringify({question:c.question,questionHash:source.questionHash,units:source.units.map(({id,text})=>({id,text}))})}]}];
 body.text.format.schema=wire(taskPlanSchemaV4(c.question));if(variant==='candidate')body.instructions+=rules;
 if(Buffer.byteLength(JSON.stringify(body))>32768)throw Error('subject_role_request_size');return body;
}));
export function subjectRoleTaskPlannerRequest(index,variant){
 if(arguments.length!==2||!Number.isInteger(index)||index<0||index>=12||!variants.includes(variant))throw Error('invalid_subject_role_request');return structuredClone(bodies[variants.indexOf(variant)][index]);
}
export function subjectRoleTaskPlannerManifest(){
 if(arguments.length)throw Error('invalid_subject_role_manifest');return {version:1,contractVersion:4,promptPolicyVersion:'subject-role-v1',syntheticOnly:true,questionCount:12,variants:[...variants],externalCalls:0,modelEvaluated:false,releaseAccepted:false,questionFileHash:hash(raw),parentReferenceRequestHash,rulesHash:hash(rules),rows:variants.flatMap((variant,v)=>bodies[v].map((body,index)=>({variant,index,caseId:fixture.cases[index].id,questionHash:JSON.parse(body.input[0].content[0].text).questionHash,requestHash:hash(JSON.stringify(body)),instructionsHash:hash(body.instructions),schemaHash:hash(JSON.stringify(body.text.format.schema)),bytes:Buffer.byteLength(JSON.stringify(body))})))};
}
