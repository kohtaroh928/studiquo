// Pure literal-key reflection check for bounded JSON. No IO, logs or key loading.
export const UNIT_SECRET_GUARD_LIMITS=Object.freeze({bytes:262144,depth:64,nodes:65536});
const fail=code=>{throw Error('unit_secret_guard_'+code);};
export function assertUnitPlannerSecretFree(raw,key){
 if(arguments.length!==2||typeof raw!=='string'||!raw.trim()||Buffer.byteLength(raw)>UNIT_SECRET_GUARD_LIMITS.bytes||typeof key!=='string'||!/^[A-Za-z0-9_-]{16,512}$/.test(key))fail('input');
 if(raw.includes(key))fail('reflection');
 let parsed;try{parsed=JSON.parse(raw);}catch{fail('json');}
 const stack=[{value:parsed,depth:0}];let visited=0;
 while(stack.length){
  const {value,depth}=stack.pop();if(++visited>UNIT_SECRET_GUARD_LIMITS.nodes||depth>UNIT_SECRET_GUARD_LIMITS.depth)fail('limits');
  if(typeof value==='string'){if(value.includes(key))fail('reflection');}
  else if(value!==null&&typeof value==='object'){
   for(const name of Object.keys(value)){
    if(name.includes(key))fail('reflection');
    if(stack.length+visited>=UNIT_SECRET_GUARD_LIMITS.nodes)fail('limits');stack.push({value:value[name],depth:depth+1});
   }
  }
 }
}
