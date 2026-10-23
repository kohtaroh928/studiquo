// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {isolationCases,isolationRequest,isolate,errorHint} from '../scripts/rag-quality/gemini-isolate.ts';
const fixture=JSON.parse(await readFile(new URL('../scripts/rag-quality/citation-intent-fixture.json',import.meta.url)));
const c=fixture.cases.find(c=>c.id==='biology-comparison');
const good=()=>Response.json({modelVersion:'gemini-3.6-flash',candidates:[{finishReason:'STOP',content:{parts:[{text:'{"ok":true}'}]}}]});
test('full input pair differs only in responseJsonSchema',()=>{
 const specs=isolationCases(c),d=structuredClone(specs[3].body),e=structuredClone(specs[4].body);delete e.generationConfig.responseJsonSchema;assert.deepEqual(d,e);assert.equal(specs[3].task.snapshot,specs[4].task.snapshot);
});
test('hint exposes only booleans and never arbitrary messages',()=>{
 const h=errorHint({error:{message:'SECRET project: high demand and grammar'}});assert.deepEqual(h,{capacityMentioned:true,schemaMentioned:true});assert.ok(!JSON.stringify(h).includes('SECRET'));
});
test('successful ladder is sequential max5 calls without response text',async()=>{
 let calls=0;const report=await isolate(c,{apiKey:'synthetic',fetchImpl:async(url,o)=>{calls++;assert.ok(!url.includes('synthetic'));assert.equal(o.redirect,'error');assert.equal(o.headers['x-goog-api-key'],'synthetic');return good();}});assert.equal(calls,5);assert.equal(report.requests.length,5);assert.equal(report.requests[1].controlValidity.valid,true);assert.ok(report.requests.every(r=>r.outcome==='completed'));assert.ok(report.requests[4].proposalValidity&&!report.requests[4].proposalValidity.valid);assert.ok(!JSON.stringify(report).includes('"ok"'));
});
for(const code of [401,403,429])test(`HTTP${code} stops even with malformed error body`,async()=>{
 let n=0;const out=await isolate(c,{apiKey:'synthetic',fetchImpl:async()=>{n++;return new Response('{',{status:code});}});assert.equal(n,1);assert.equal(out.requests[0].httpStatus,code);
});
test('503 runs at most one post-control and never retries the failed request',async()=>{
 let n=0;const out=await isolate(c,{apiKey:'synthetic',fetchImpl:async()=>{n++;return n===1?good():Response.json({error:{status:'UNAVAILABLE',message:'high demand SECRET'}},{status:503});}});assert.equal(n,3);assert.deepEqual(out.requests.map(r=>r.id),['A_text_control','B_tiny_schema','F_post_control']);assert.equal(out.requests[1].hint.capacityMentioned,true);assert.ok(!JSON.stringify(out).includes('SECRET'));
});
test('first control failure ends the ladder without post-control',async()=>{
 let n=0;const out=await isolate(c,{apiKey:'synthetic',fetchImpl:async()=>{n++;return new Response('{',{status:503});}});assert.equal(n,1);assert.equal(out.requests.length,1);
});
test('timeout covers request and body with bounded results',async()=>{
 const out=await isolationRequest(isolationCases(c)[0],{apiKey:'synthetic',timeoutMs:10,fetchImpl:async()=>new Response(new ReadableStream({start(){}}))});assert.equal(out.outcome,'timeout');assert.equal(out.httpStatus,200);
});
test('oversized error body cannot leak text',async()=>{
 const out=await isolationRequest(isolationCases(c)[0],{apiKey:'synthetic',fetchImpl:async()=>new Response('SECRET'.repeat(3000),{status:429})});assert.equal(out.httpStatus,429);assert.equal(out.outcome,'transport_or_body_failure');assert.ok(!JSON.stringify(out).includes('SECRET'));
});
