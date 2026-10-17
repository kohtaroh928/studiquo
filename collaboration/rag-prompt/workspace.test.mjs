import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {validateCandidate,preparePacket,summary} from './workspace.mjs';
const candidate=JSON.parse(readFileSync(new URL('./candidates/example.json',import.meta.url),'utf8'));
test('fixed comparison preserves all input/configuration and changes only instructions',()=>{
 const packet=preparePacket(candidate);
 assert.equal(packet.pairs.length,12);
 assert.equal(new Set(packet.pairs.map(p=>p.caseKey)).size,6);
 for(const row of packet.pairs){
  const {instructions:a,...left}=row.baseline;
  const {instructions:b,...right}=row.candidate;
  assert.deepEqual(left,right);
  assert.equal(b,a+'\n\n'+candidate.additionalInstructions);
  assert.notEqual(row.baselineHash,row.candidateHash);
  assert.ok(['source_only','explain'].includes(row.style));
 }
 assert.equal(packet.externalCalls,0);
 assert.equal(summary(packet).qualityVerdict,'not_evaluated');
 assert.equal(JSON.stringify(summary(packet)).includes(candidate.additionalInstructions),false);
});
test('candidate rejects executable extensions, unknown fields, wrong baseline and excessive text',()=>{
 for(const c of [null,[],{...candidate,id:'../escape'}, {...candidate,version:2},
   {...candidate,baselineId:'other'}, {...candidate,apiKey:'placeholder'},
   {...candidate,additionalInstructions:''}, {...candidate,additionalInstructions:'文'.repeat(6000)}]){
   assert.throws(()=>validateCandidate(c),/invalid_candidate/);
 }
});
test('packets are deterministic and do not share mutable bodies between variants or runs',()=>{
 const a=preparePacket(candidate),b=preparePacket(candidate);
 assert.deepEqual(a,b);
 a.pairs[0].candidate.input=[];
 assert.notDeepEqual(a.pairs[0].candidate.input,a.pairs[0].baseline.input);
 assert.deepEqual(preparePacket(candidate),b);
});
