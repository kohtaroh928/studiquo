// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {timeoutSpecs,diagnoseParagraphTimeout} from '../scripts/rag-quality/paragraph-timeout-diagnose.ts';
import {isolationRequest} from '../scripts/rag-quality/gemini-isolate.ts';
import {paragraphMessages,paragraphSchema,validateParagraphProposal} from '../scripts/rag-quality/paragraph-proposal.ts';
import {geminiProposer} from '../scripts/rag-quality/selection-proposal-gemini.ts';
const f=JSON.parse(await readFile(new URL('../scripts/rag-quality/citation-intent-fixture.json',import.meta.url))),c=f.cases.find(c=>c.id==='hidden-condition');
const specs=timeoutSpecs(c);
const response=task=>Response.json({modelVersion:'gemini-3.6-flash',candidates:[{finishReason:'STOP',content:{parts:[{text:JSON.stringify({version:2,snapshot:task.snapshot,decision:'select',decisions:task.references.map(r=>({referenceId:r.id,action:'retain',reason:'answer',paragraphIds:[task.paragraphs.find(p=>p.referenceId===r.id).id]}))})}]}}]});
test('target body equals the actual timed-out protocol2 adapter request; only deadline changes',async()=>{
 const target=specs[1];let body;
 await geminiProposer({apiKey:'synthetic',schema:paragraphSchema,fetchImpl:async(url,o)=>{body=JSON.parse(o.body);return response(target.task);}})(paragraphMessages(target.task),{signal:new AbortController().signal});
 assert.deepEqual(target.body,body);assert.deepEqual(specs[0].body.generationConfig,target.body.generationConfig);assert.deepEqual(specs[0].body,specs[2].body);
});
test('three calls are serial, paced, structurally validated and text-free',async()=>{
 let calls=0;const waits=[];
 const out=await diagnoseParagraphTimeout(c,{apiKey:'synthetic',intervalMs:31,wait:async n=>waits.push(n),fetchImpl:async(url,o)=>{
  const task=specs[calls++].task;assert.equal(o.redirect,'error');assert.equal(o.headers['x-goog-api-key'],'synthetic');return response(task);
 }});
 assert.equal(calls,3);assert.deepEqual(waits,[31,31]);assert.ok(out.requests.every(r=>r.phase==='complete'&&r.completeMs>=r.headersMs&&r.proposalValidity.valid));
 assert.ok(!JSON.stringify(out).includes(c.question));assert.ok(!JSON.stringify(out).includes('合成価格'));assert.equal(out.requests[0].requestHash,out.requests[2].requestHash);
});
test('timeout before headers has no status or completed body and aborts request',async()=>{
 let signal;
 const row=await isolationRequest(specs[1],{apiKey:'synthetic',timeoutMs:10,proposalValidator:validateParagraphProposal,fetchImpl:async(u,o)=>{signal=o.signal;await new Promise(()=>{});}});
 assert.equal(row.outcome,'timeout');assert.equal(row.phase,'pre_headers');assert.equal(row.headersMs,null);assert.equal(row.completeMs,null);assert.equal(row.httpStatus,null);assert.equal(signal.aborted,true);
});
test('headers received but stalled body is distinct from request wait',async()=>{
 const row=await isolationRequest(specs[1],{apiKey:'synthetic',timeoutMs:10,proposalValidator:validateParagraphProposal,fetchImpl:async()=>new Response(new ReadableStream({start(){}}))});
 assert.equal(row.phase,'response_processing');assert.equal(row.httpStatus,200);assert.equal(row.completeMs,null);assert.ok(row.headersMs>=0);
});
test('late ignored abort cannot rewrite returned deadline observation',async()=>{
 const row=await isolationRequest(specs[1],{apiKey:'synthetic',timeoutMs:5,proposalValidator:validateParagraphProposal,fetchImpl:async()=>{await new Promise(r=>setTimeout(r,20));return response(specs[1].task);}});
 const saved=JSON.stringify(row);await new Promise(r=>setTimeout(r,30));assert.equal(JSON.stringify(row),saved);assert.equal(row.phase,'pre_headers');
});
test('malformed response remains processing failure without exposing raw data',async()=>{
 const row=await isolationRequest(specs[1],{apiKey:'synthetic',proposalValidator:validateParagraphProposal,fetchImpl:async()=>new Response('PRIVATE_BODY')});
 assert.equal(row.phase,'response_processing');assert.equal(row.outcome,'transport_or_body_failure');assert.ok(!JSON.stringify(row).includes('PRIVATE_BODY'));
});
for(const code of [401,403,429,503])test(`HTTP${code} stops the diagnostic with no extra call or retry`,async()=>{
 let calls=0;const out=await diagnoseParagraphTimeout(c,{apiKey:'synthetic',intervalMs:0,fetchImpl:async()=>{calls++;return new Response('{',{status:code});}});
 assert.equal(calls,1);assert.equal(out.requests.length,1);assert.equal(out.requests[0].httpStatus,code);
});
test('invalid diagnostics configuration never calls provider',async()=>{
 let calls=0;const fetchImpl=async()=>{calls++;};
 for(const options of [{timeoutMs:20001},{intervalMs:60001},{intervalMs:-1}])await assert.rejects(diagnoseParagraphTimeout(c,{apiKey:'synthetic',fetchImpl,...options}));
 assert.equal(calls,0);
});
