// Offline fixed synthetic requests only. No transport, key loading or oracle.
import {createHash} from 'node:crypto';
import {pairedTaskPlannerRequest} from './paired-task-planner-request.mjs';
import {taskPlanSchemaV3} from './task-plan-quoted-v3.mjs';
const hash=x=>createHash('sha256').update(x).digest('hex');
const oldQuotes='Use ids t1, t2, etc. Every attribute, subject, condition and requestSpans entry must be an exact nonempty quote of the original question with zero-based UTF-16 start inclusive and end exclusive offsets. Do not normalize or rewrite quotes. Attribute is the requested answer scope; subjects identify its entities; conditions retain the question\'s qualifications; requestSpans identify the wording requesting that operation. Use empty subject/condition arrays when absent. Never invent offsets or subjects.';
const newQuotes='Use ids t1, t2, etc. Every attribute, subject, condition and requestSpans entry must be an exact nonempty quote of the original question represented as {text,prefix,suffix}. text is the quote (at most 4096 UTF-16 code units); prefix and suffix are exact immediately adjacent original text before and after it (each at most 128 UTF-16 code units, empty allowed). For repeated quotes, include enough adjacent context to identify exactly one occurrence; never choose the first occurrence merely because it is first. Do not normalize, rewrite or invent quotes or context. Do not output numeric character positions. The server resolves positions only when the quote and its context match exactly one original location. Attribute is the requested answer scope; subjects identify its entities; conditions retain the question\'s qualifications; requestSpans identify the wording requesting that operation. Use empty subject/condition arrays when absent. Never invent subjects. Apply the same quote representation to unresolved spans. Preserve valid Unicode scalar boundaries; do not split surrogate pairs.';
function replaceOnce(text,from,to){if(text.split(from).length!==2)throw Error('quoted_planner_parent_changed');return text.replace(from,to);}
function wireSchema(value){
 if(Array.isArray(value))return value.map(wireSchema);
 if(!value||typeof value!=='object')return value;
 const out={};for(const [key,v] of Object.entries(value)){
  if(key==='const')out.enum=[v];else if(key!=='minLength'&&key!=='maxLength')out[key]=wireSchema(v);
 }return out;
}
const bodies=[],parentHashes=[];
for(let index=0;index<8;index++){
 const body=pairedTaskPlannerRequest(index,'candidate');parentHashes.push(hash(JSON.stringify(body)));
 body.instructions=replaceOnce(replaceOnce(body.instructions,'Return TaskPlan v2 only.','Return TaskPlan v3 only.'),oldQuotes,newQuotes);
 if(/TaskPlan v2|zero-based|start inclusive|end exclusive|invent offsets/.test(body.instructions))throw Error('quoted_planner_parent_changed');
 body.text.format={type:'json_schema',name:'task_plan_quoted_v3',strict:true,schema:wireSchema(taskPlanSchemaV3())};
 if(Buffer.byteLength(JSON.stringify(body))>24576)throw Error('quoted_planner_request_size');bodies.push(body);
}
export function quotedTaskPlannerRequest(index){
 if(arguments.length!==1||!Number.isInteger(index)||index<0||index>=8)throw Error('invalid_quoted_planner_index');
 return structuredClone(bodies[index]);
}
export function quotedTaskPlannerManifest(){
 if(arguments.length)throw Error('invalid_quoted_planner_manifest');
 return {version:1,contractVersion:3,syntheticOnly:true,questionCount:8,externalCalls:0,modelEvaluated:false,releaseAccepted:false,
  instructionsHash:hash(bodies[0].instructions),schemaHash:hash(JSON.stringify(bodies[0].text.format.schema)),
  rows:bodies.map((body,index)=>({index,parentCandidateRequestHash:parentHashes[index],questionHash:hash(JSON.parse(body.input[0].content[0].text).question),requestHash:hash(JSON.stringify(body)),bytes:Buffer.byteLength(JSON.stringify(body))}))};
}
