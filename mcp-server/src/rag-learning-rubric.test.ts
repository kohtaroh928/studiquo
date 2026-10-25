import test from 'node:test';
import assert from 'node:assert/strict';
import {learningPairs,learningPrompt} from '../scripts/rag-quality/learning-fixture.ts';
import {LEARNING_RUBRIC_VERSION,learningReviewChecks} from '../scripts/rag-quality/learning-rubric.ts';
import {runOpenAIPilot} from '../scripts/rag-quality/learning-openai-live.ts';

test('versioned rubric preserves legacy criteria and distinguishes paraphrases from external background',()=>{
 const pair=learningPairs.find(p=>p.id==='learning-density-background');
 const before=JSON.stringify(pair.manualChecks);
 const prompt=learningPrompt(pair,'explain');
 const checks=learningReviewChecks(pair,'explain');
 assert.match(checks.join('\n'),/直接の言い換えには補足表示を必須としない/);
 assert.match(checks.join('\n'),/未記載の性質・用途・たとえは最初の説明より前に補足/);
 assert.match(checks.join('\n'),/合計質量と体積あたりの質量を混同しない/);
 checks.push('local-only');
 assert.equal(JSON.stringify(pair.manualChecks),before);
 assert.equal(learningPrompt(pair,'explain'),prompt);
 assert.throws(()=>learningReviewChecks({...pair},'explain'));
 assert.throws(()=>learningReviewChecks(pair,'other'));
});

test('live pilot records versioned and legacy criteria without leaking rubric into requests',async()=>{
 const requests=[];
 const result=await runOpenAIPilot({apiKey:'synthetic-rubric-key',caseIds:['learning-density-background','learning-partial-devices'],fetchImpl:async(_,options)=>{
  requests.push(JSON.parse(options.body));
  return new Response('data: {"type":"response.output_text.delta","delta":"synthetic answer"}\n\ndata: {"type":"response.completed","response":{"status":"completed","model":"gpt-6-luna","usage":{"input_tokens":12,"output_tokens":5,"total_tokens":17}}}\n\n');
 }});
 assert.equal(result.dispatches,4);
 for(const row of result.rows) {
  assert.equal(row.rubricVersion,LEARNING_RUBRIC_VERSION);
  assert.equal(row.manualReview,'pending');
  const pair=learningPairs.find(p=>p.id===row.id);
  assert.deepEqual(row.legacyManualChecks,[...pair.manualChecks.common,...pair.manualChecks[row.style]]);
  assert.deepEqual(row.manualChecks,learningReviewChecks(pair,row.style));
 }
 const serialized=JSON.stringify(requests);
 assert.ok(!serialized.includes(LEARNING_RUBRIC_VERSION));
 assert.ok(!serialized.includes('直接の言い換えには補足表示を必須としない'));
 assert.ok(!serialized.includes('片側の既知仕様は対象名付き'));
});
