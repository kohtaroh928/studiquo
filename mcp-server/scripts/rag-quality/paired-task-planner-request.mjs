// Offline paired comparison only. No key loading, transport or oracle import.
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {taskPlannerRequest} from './task-planner-request.mjs';
const hash=x=>createHash('sha256').update(x).digest('hex');
const raw=readFileSync(new URL('task-plan-paired-draft.json',import.meta.url));
if(hash(raw)!=='da62542b60cc32a348faad176a71bc11266829e9220d1d5659561cc026d2bf43')throw Error('paired_draft_changed');
const draft=JSON.parse(raw);
if(draft.syntheticOnly!==true||draft.split!=='separate-development'||draft.cases.length!==8)throw Error('invalid_paired_draft');
const questions=Object.freeze(draft.cases.map(c=>c.question));
const clarification=`
Additional scope annotation rules:
1. For independently requested values, retain a separate answer slot for each explicitly requested subject, attribute and applicability situation. Repeating one attribute across subjects or situations can require separate value tasks.
2. A comparison of one attribute or viewpoint across subjects remains one relational task containing those subjects. Preserve separately requested comparison viewpoints. A joint summary across sources is not split merely by source count.
3. Choose an original noun phrase or relationship denoting the answer scope as attribute. A question word or request verb alone must not replace that scope. Explaining a comparison method does not request performing that comparison.
4. Put explicit applicability situations in conditions even if their words also occur inside an attribute quote. Distinguish a concept whose conditions are being requested from a condition qualifying the answer; do not move every topic into conditions.
5. Never invent absent subjects, attributes or conditions to fill slots. Preserve ambiguity when necessary. resolution, evidenceSupport and comparisonPermission remain unknown; extraction does not establish source support or permission to compare.`;
const variants=Object.freeze(['baseline','candidate']);
const bodies=variants.map(variant=>questions.map(question=>{
 if(typeof question!=='string'||!question.trim()||Buffer.byteLength(question)>16384)throw Error('invalid_paired_question');
 const body=taskPlannerRequest(0);
 body.input=[{role:'user',content:[{type:'input_text',text:JSON.stringify({question})}]}];
 if(variant==='candidate')body.instructions+=clarification;
 if(Buffer.byteLength(JSON.stringify(body))>24576)throw Error('paired_request_too_large');
 return body;
}));
export function pairedTaskPlannerRequest(index,variant){
 if(arguments.length!==2||!Number.isInteger(index)||index<0||index>=8||!variants.includes(variant))throw Error('invalid_paired_request');
 return structuredClone(bodies[variants.indexOf(variant)][index]);
}
export function pairedTaskPlannerManifest(){
 if(arguments.length)throw Error('invalid_paired_manifest');
 return {version:1,syntheticOnly:true,externalCalls:0,modelEvaluated:false,releaseAccepted:false,draftHash:hash(raw),
  questionOrderHash:hash(JSON.stringify(questions)),clarificationHash:hash(clarification),
  rows:variants.flatMap((variant,v)=>bodies[v].map((body,index)=>({variant,index,questionHash:hash(questions[index]),
   instructionsHash:hash(body.instructions),requestHash:hash(JSON.stringify(body)),bytes:Buffer.byteLength(JSON.stringify(body))})))};
}
