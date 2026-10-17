// Fixed synthetic offline v4 requests. No transport, keys, oracle or review import.
import {createHash} from 'node:crypto';
import {pairedTaskPlannerRequest} from './paired-task-planner-request.mjs';
import {createQuestionUnits} from './question-units.mjs';
import {taskPlanSchemaV4} from './task-plan-units-v4.mjs';
const hash=x=>createHash('sha256').update(x).digest('hex');
const oldQuotes="Use ids t1, t2, etc. Every attribute, subject, condition and requestSpans entry must be an exact nonempty quote of the original question with zero-based UTF-16 start inclusive and end exclusive offsets. Do not normalize or rewrite quotes. Attribute is the requested answer scope; subjects identify its entities; conditions retain the question's qualifications; requestSpans identify the wording requesting that operation. Use empty subject/condition arrays when absent. Never invent offsets or subjects.";
const unitRules="Use ids t1, t2, etc. Copy questionHash from the user JSON without recomputing it. Represent each attribute, subject and condition as {label,unitIds}. label is a concise interpretation of the requested role (at most 256 UTF-16 code units), not an exact quote or verified fact. unitIds are unique existing ids from the supplied units that contain the relevant question wording. Attribute is the requested answer scope; subjects identify its entities; conditions retain the question's qualifications. requestUnitIds identify the units requesting the operation. Each reference list must be nonempty and contain only existing ids; do not invent ids or numeric character positions. Units are structural parts of the question, not atomic answer requirements, retrieved sources or evidence of semantic support. A single unit may support several independent tasks. Do not use all units indiscriminately for every role. Use empty subject/condition arrays when absent. Never invent subjects, qualifications or answers. Return at most 16 tasks, 4 subjects and 4 conditions per task, and 8 unresolved entries. Represent unresolved entries as {kind,unitIds}, referring to the relevant question units.";
const replaceOnce=(text,from,to)=>{if(text.split(from).length!==2)throw Error('unit_planner_parent_changed');return text.replace(from,to);};
function wireSchema(value){
 if(Array.isArray(value))return value.map(wireSchema);
 if(!value||typeof value!=='object')return value;
 const out={};for(const [k,v] of Object.entries(value))if(k!=='minLength'&&k!=='maxLength')out[k]=wireSchema(v);return out;
}
const bodies=[],rows=[];
for(let index=0;index<8;index++){
 const body=pairedTaskPlannerRequest(index,'candidate'),parentCandidateRequestHash=hash(JSON.stringify(body));
 const question=JSON.parse(body.input[0].content[0].text).question,source=createQuestionUnits(question);
 if(source.status!=='supported')throw Error('unit_planner_question_unsupported');
 body.instructions=replaceOnce(replaceOnce(replaceOnce(body.instructions,'Return TaskPlan v2 only.','Return TaskPlan v4 only.'),oldQuotes,unitRules),'an unresolved entry of kind reference quoting the referent','an unresolved entry of kind reference referring to its unitIds');
 if(/TaskPlan v[23]|zero-based|start inclusive|end exclusive|prefix|suffix|requestSpans|quoting the referent/.test(body.instructions))throw Error('unit_planner_parent_changed');
 body.input=[{role:'user',content:[{type:'input_text',text:JSON.stringify({question,questionHash:source.questionHash,units:source.units.map(({id,text})=>({id,text}))})}]}];
 body.text.format={type:'json_schema',name:'task_plan_units_v4',strict:true,schema:wireSchema(taskPlanSchemaV4(question))};
 const serialized=JSON.stringify(body),bytes=Buffer.byteLength(serialized);if(bytes>32768)throw Error('unit_planner_request_size');
 rows.push({index,parentCandidateRequestHash,questionHash:source.questionHash,instructionsHash:hash(body.instructions),schemaHash:hash(JSON.stringify(body.text.format.schema)),requestHash:hash(serialized),bytes});bodies.push(body);
}
export function unitTaskPlannerRequest(index){
 if(arguments.length!==1||!Number.isInteger(index)||index<0||index>=8)throw Error('invalid_unit_planner_index');return structuredClone(bodies[index]);
}
export function unitTaskPlannerManifest(){
 if(arguments.length)throw Error('invalid_unit_planner_manifest');return {version:1,contractVersion:4,syntheticOnly:true,questionCount:8,externalCalls:0,modelEvaluated:false,releaseAccepted:false,requestBytesLimit:32768,rows:structuredClone(rows)};
}
