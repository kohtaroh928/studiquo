// Offline structural validation only. No oracle, policy inference, I/O or transport.
import {createHash} from 'node:crypto';
const fail=(code: any)=>{throw Error('clarification_'+code);};
const exact=(o: any,ks: any)=>o!==null&&typeof o==='object'&&!Array.isArray(o)&&Object.keys(o).length===ks.length&&ks.every((k: any)=>Object.hasOwn(o,k));
const one=(v: any,vs: any)=>vs.includes(v);
const text=(v: any,max: any,nonempty=false)=>typeof v==='string'&&(!nonempty||v.trim().length>0)&&v.length<=max&&Buffer.from(v,'utf8').toString('utf8')===v;
const hash=(v: any)=>createHash('sha256').update(JSON.stringify(v)).digest('hex');
const scope=(c: any)=>c.kind.startsWith('scope_');
function parse(raw: any,limit: any,kind: any){if(typeof raw!=='string'||!raw.trim()||Buffer.byteLength(raw)>limit)fail(kind+'_size');try{return JSON.parse(raw);}catch{fail(kind+'_json');}}
function input(raw: any){
 const i=parse(raw,65536,'input');
 if(!exact(i,['version','mode','question','contextItems'])||i.version!==1||!one(i.mode,['question_only','contextual_pre_search','scoped_inspection'])||!text(i.question,16384,true)||Buffer.byteLength(i.question)>16384||!Array.isArray(i.contextItems)||i.contextItems.length>16)fail('input_shape');
 const ids=new Set();
 for(const c of i.contextItems){
  if(!exact(c,['id','kind','availability','text','revision','scopeRef','outcome'])||typeof c.id!=='string'||!/^c(?:[1-9]|1[0-6])$/.test(c.id)||ids.has(c.id)||!one(c.kind,['user_history','scope_page','scope_notebook','scope_folder','scope_library','inspection'])||!one(c.availability,['available','unavailable'])||!text(c.text,8192)||Buffer.byteLength(c.text)>8192||!text(c.revision,64,true))fail('context_shape');
  ids.add(c.id);if(c.availability==='unavailable'&&c.text!=='')fail('withheld_text');
  if(c.kind!=='inspection'&&(c.scopeRef!==null||c.outcome!==null))fail('context_shape');
 }
 if(i.mode==='question_only'&&i.contextItems.length||i.mode==='contextual_pre_search'&&i.contextItems.some((c: any)=>c.kind==='inspection'))fail('phase');
 if(i.mode==='scoped_inspection'&&(!i.contextItems.some(scope)||!i.contextItems.some((c: any)=>c.kind==='inspection')))fail('phase');
 for(const c of i.contextItems.filter((c: any)=>c.kind==='inspection')){
  const s=i.contextItems.find((s: any)=>scope(s)&&s.id===c.scopeRef);
  if(!s||s.revision!==c.revision||!one(c.outcome,['content','no_hits','failed','unavailable']))fail('inspection_binding');
  if(one(c.outcome,['content','no_hits'])&&(c.availability!=='available'||s.availability!=='available'))fail('inspection_availability');
  if(c.outcome==='content'&&!c.text.trim()||c.outcome!=='content'&&c.text!=='')fail('inspection_text');
  if(one(c.outcome,['failed','unavailable'])&&c.availability!=='unavailable')fail('inspection_availability');
 }
 return i;
}
export function clarificationInputBinding(rawInput: any){
 if(arguments.length!==1)fail('arguments');const i=input(rawInput);return {version:1,inputHash:hash(i),input:i};
}
export function validateClarificationDecision(rawInput: any,rawDecision: any){
 if(arguments.length!==2)fail('arguments');const i=input(rawInput),inputHash=hash(i),d=parse(rawDecision,32768,'decision');
 if(!exact(d,['version','inputHash','technicalState','decisions'])||d.version!==1||d.inputHash!==inputHash||!one(d.technicalState,['ok','unsupported','failed'])||!Array.isArray(d.decisions)||d.decisions.length>16)fail('decision_shape');
 if(d.technicalState!=='ok'&&d.decisions.length||d.technicalState==='ok'&&!d.decisions.length)fail('technical_state');
 const ids=new Set(),observations=i.contextItems.filter((c: any)=>c.kind==='inspection');
 for(const t of d.decisions){
  if(!exact(t,['id','requestLabel','requestRefs','targetState','basis','targetRefs','evidenceState','nextAction','inspectionPurpose'])||typeof t.id!=='string'||!/^d(?:[1-9]|1[0-6])$/.test(t.id)||ids.has(t.id)||!text(t.requestLabel,256,true)||!Array.isArray(t.requestRefs)||t.requestRefs.length!==1||t.requestRefs[0]!=='q'||!Array.isArray(t.targetRefs)||t.targetRefs.length>17||new Set(t.targetRefs).size!==t.targetRefs.length||!one(t.targetState,['single','set','not_required','unresolved','uncertain'])||!one(t.basis,['question','history','selected_scope','inspection','none'])||!one(t.evidenceState,['not_checked','supported','insufficient','conflicting','no_hits','unavailable'])||!one(t.nextAction,['proceed','inspect_scope','clarify_target','review_required'])||!one(t.inspectionPurpose,['none','target','content']))fail('decision_fields');
  ids.add(t.id);
  const refs=t.targetRefs.filter((r: any)=>r!=='q').map((r: any)=>i.contextItems.find((c: any)=>c.id===r));
  if(refs.some((c: any)=>!c||c.availability!=='available'))fail('reference');
  const resolved=one(t.targetState,['single','set']);
  if(resolved&&(t.basis==='none'||!t.targetRefs.length)||t.targetState==='not_required'&&(t.basis!=='question'||t.targetRefs.length!==1||t.targetRefs[0]!=='q')||one(t.targetState,['unresolved','uncertain'])&&(t.basis!=='none'||t.targetRefs.length))fail('target_state');
  if(t.basis==='none'&&t.targetRefs.length||t.basis==='question'&&(t.targetRefs.length!==1||t.targetRefs[0]!=='q'))fail('basis');
  if(t.basis==='history'&&(!refs.length||refs.some((c: any)=>c.kind!=='user_history')))fail('basis');
  if(t.basis==='selected_scope'&&(!refs.length||refs.some((c: any)=>!scope(c))))fail('basis');
  if(t.basis==='inspection'){
   const obs=refs.filter((c: any)=>c.kind==='inspection'),scopes=refs.filter(scope);
   if(!obs.length||refs.some((c: any)=>c.kind!=='inspection'&&!scope(c))||obs.some((c: any)=>c.outcome!=='content'||!scopes.some((s: any)=>s.id===c.scopeRef))||scopes.some((s: any)=>!obs.some((c: any)=>c.scopeRef===s.id)))fail('basis');
  }
  if(i.mode==='question_only'&&!one(t.basis,['question','none'])||i.mode!=='scoped_inspection'&&t.evidenceState!=='not_checked')fail('phase');
  if(one(t.evidenceState,['supported','insufficient','conflicting'])&&!observations.some((c: any)=>c.outcome==='content'&&c.availability==='available')||t.evidenceState==='no_hits'&&!observations.some((c: any)=>c.outcome==='no_hits')||t.evidenceState==='unavailable'&&!observations.some((c: any)=>one(c.outcome,['failed','unavailable'])))fail('evidence_observation');
  if(t.nextAction==='proceed'&&!one(t.targetState,['single','set','not_required'])||t.nextAction==='clarify_target'&&t.targetState!=='unresolved'||t.nextAction==='review_required'&&t.targetState!=='uncertain')fail('action');
  if(t.nextAction==='inspect_scope'){
   if(!i.contextItems.some((c: any)=>scope(c)&&c.availability==='available')||!one(t.targetState,['single','set','unresolved'])||t.inspectionPurpose!==(resolved?'content':'target'))fail('inspection_action');
  }else if(t.inspectionPurpose!=='none')fail('inspection_action');
 }
 return {version:1,inputHash,decision:d,semantics:'pending',technicalStateVerified:false,authorizationVerified:false,releaseAccepted:false};
}
