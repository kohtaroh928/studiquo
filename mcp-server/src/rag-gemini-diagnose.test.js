import test from 'node:test';
import assert from 'node:assert/strict';
import {safeError,diagnose} from '../scripts/rag-quality/gemini-diagnose.mjs';
test('error diagnostics strip sensitive message/project and keep bounded known fields',()=>{
 const out=safeError({error:{status:'RESOURCE_EXHAUSTED',message:'SECRET key project123',details:[{'@type':'type.googleapis.com/google.rpc.QuotaFailure',violations:[{quotaMetric:'generate_content_free_tier_requests',quotaId:'GenerateRequestsPerDayPerProject',quotaValue:'0',subject:'project123',description:'SECRET'}]},{'@type':'type.googleapis.com/google.rpc.RetryInfo',retryDelay:'12.5s'},{'@type':'type.googleapis.com/google.rpc.ErrorInfo',reason:'RATE_LIMIT_EXCEEDED',metadata:{project:'project123'}}]}});
 assert.deepEqual(out,{status:'RESOURCE_EXHAUSTED',reason:'RATE_LIMIT_EXCEEDED',quotas:[{tier:'free',window:'day',limit:0}],retrySeconds:12.5});assert.ok(!JSON.stringify(out).includes('SECRET'));assert.ok(!JSON.stringify(out).includes('project123'));
});
test('unknown reasons and malformed numeric values are not copied',()=>{
 const out=safeError({error:{status:'PRIVATE',details:[{'@type':'type.googleapis.com/google.rpc.ErrorInfo',reason:'PRIVATE'},{'@type':'type.googleapis.com/google.rpc.RetryInfo',retryDelay:'Infinitys'},{'@type':'type.googleapis.com/google.rpc.QuotaFailure',violations:[{quotaValue:'Infinity',quotaMetric:'SECRET',quotaId:'PRIVATE'}]}]}});assert.equal(out.status,'unknown');assert.equal(out.reason,null);assert.equal(out.retrySeconds,null);assert.deepEqual(out.quotas,[{tier:'unknown',window:'unknown',limit:null}]);
});
test('single current-model probe uses a header key and never returns response text',async()=>{
 let calls=0;const out=await diagnose({apiKey:'synthetic',fetchImpl:async(url,o)=>{calls++;assert.match(url,/gemini-3.6-flash:generateContent$/);assert.ok(!url.includes('synthetic'));assert.equal(o.redirect,'error');assert.equal(o.headers['x-goog-api-key'],'synthetic');return Response.json({candidates:[{finishReason:'STOP',content:{parts:[{text:'SENSITIVE_OUTPUT'}]}}],modelVersion:'gemini-3.6-flash',usageMetadata:{promptTokenCount:4,candidatesTokenCount:2,totalTokenCount:6}});}});assert.equal(out.outcome,'available');assert.equal(calls,1);assert.ok(!JSON.stringify(out).includes('SENSITIVE_OUTPUT'));assert.equal(out.usage.total,6);
});
test('quota error is sanitised and not retried',async()=>{
 let calls=0;const out=await diagnose({apiKey:'synthetic',fetchImpl:async()=>{calls++;return Response.json({error:{status:'RESOURCE_EXHAUSTED',message:'PRIVATE'}},{status:429});}});assert.equal(calls,1);assert.equal(out.outcome,'http_error');assert.equal(out.httpStatus,429);assert.ok(!JSON.stringify(out).includes('PRIVATE'));
});
test('response size and malformed JSON fail safely',async()=>{
 for(const raw of ['x'.repeat(16385),'{']){const out=await diagnose({apiKey:'synthetic',fetchImpl:async()=>new Response(raw)});assert.equal(out.outcome,'transport_or_body_failure');}
});
test('request and body timeout stay bounded with an aborted signal',async()=>{
 let signal;const out=await diagnose({apiKey:'synthetic',timeoutMs:10,fetchImpl:async(_u,o)=>{signal=o.signal;return new Promise(()=>{});}});assert.equal(out.outcome,'timeout');assert.equal(signal.aborted,true);
 const body=await diagnose({apiKey:'synthetic',timeoutMs:10,fetchImpl:async()=>new Response(new ReadableStream({start(){}}))});assert.equal(body.outcome,'timeout');assert.equal(body.httpStatus,200);
});
test('2xx without a completed text answer does not prove availability',async()=>{
 for(const data of [{},{candidates:[{finishReason:'MAX_TOKENS',content:{parts:[{text:'partial'}]}}]}]){const out=await diagnose({apiKey:'synthetic',fetchImpl:async()=>Response.json(data)});assert.equal(out.outcome,'no_completed_answer');}
});

test('quota numbers reject coercible but non-decimal JSON values',()=>{
 for(const value of [' ',[],[0],'0x10',true,'1e2','-1']){const out=safeError({error:{details:[{'@type':'type.googleapis.com/google.rpc.QuotaFailure',violations:[{quotaValue:value}]}]}});assert.equal(out.quotas[0].limit,null);}
});
