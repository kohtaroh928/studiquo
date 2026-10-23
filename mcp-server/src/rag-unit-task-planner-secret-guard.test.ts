// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import {assertUnitPlannerSecretFree as check,UNIT_SECRET_GUARD_LIMITS as limits} from '../scripts/rag-quality/unit-task-planner-secret-guard.ts';
const key='synthetic_key_for_unit_guard_0001';
const escaped=[...key].map(c=>'\\u'+c.charCodeAt(0).toString(16).padStart(4,'0')).join('');
const rejects=(raw,code)=>assert.throws(()=>check(raw,key),e=>e.message==='unit_secret_guard_'+code&&!e.message.includes(key));
test('ordinary bounded response and request JSON are accepted without returning or changing data',()=>{const raw=JSON.stringify({plan:{tasks:[{attribute:{label:'料金',unitIds:['u1']}}]},usage:{input:1,output:2},flag:false,empty:null});assert.equal(check(raw,key),undefined);assert.equal(JSON.parse(raw).plan.tasks[0].attribute.label,'料金');assert.equal(check('[null,1,true,"説明"]',key),undefined);});
test('literal reflected key in response JSON is rejected with a fixed error',()=>{rejects(JSON.stringify({plan:{label:'prefix '+key+' suffix'}}),'reflection');});
test('Unicode escapes and mixed encoding cannot hide a reflected key in nested saved values',()=>{for(const encoded of [escaped,key.slice(0,8)+escaped.slice(8*6)]){const raw='{"output":[{"plan":{"label":"'+encoded+'"}}]}';assert.equal(raw.includes(key),false);rejects(raw,'reflection');}});
test('reflected keys in JSON property names are rejected after decoding',()=>{const raw='{"'+escaped+'":0}';assert.equal(raw.includes(key),false);rejects(raw,'reflection');});
test('string-only size and key format validation cannot invoke object getters or expose text',()=>{for(const raw of [null,{},new Proxy({},{get(){throw Error(key);}}),'',' '.repeat(limits.bytes+1)])rejects(raw,'input');for(const k of [undefined,{},'short',' '.repeat(16),'a'.repeat(513)])assert.throws(()=>check('{}',k),e=>e.message==='unit_secret_guard_input');assert.throws(()=>check('{}',key,{}),e=>e.message==='unit_secret_guard_input');rejects('{synthetic_private','json');});
test('byte depth and traversal limits fail closed without recursion or input repair',()=>{rejects('"'+'あ'.repeat(87382)+'"','input');check('['.repeat(64)+'0'+']'.repeat(64),key);rejects('['.repeat(65)+'0'+']'.repeat(65),'limits');rejects('['+Array(65536).fill(0).join(',')+']','limits');check('['+Array(65535).fill(0).join(',')+']',key);assert.equal(Object.isFrozen(limits),true);});
test('nested output_text JSON requires checking the final parsed save payload separately',()=>{
 const planText='{"label":"'+escaped+'"}',raw=JSON.stringify({output:[{content:[{type:'output_text',text:planText}]}]});
 assert.equal(check(raw,key),undefined);
 const saved={plan:JSON.parse(JSON.parse(raw).output[0].content[0].text)};
 rejects(JSON.stringify(saved),'reflection');
});
