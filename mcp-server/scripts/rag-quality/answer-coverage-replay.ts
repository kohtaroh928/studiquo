// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
// Offline replay of already generated SYNTHETIC answers only. No API or keys.
// Public output contains hashes/counts, never answer text or reviewer quotes.
import fs from 'node:fs';
import {createHash} from 'node:crypto';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {developmentCoverageContracts,reviewCoverage,probeExplicitDifference,coverageHash} from './answer-coverage.ts';

const hash=(s: any)=>createHash('sha256').update(s).digest('hex');
const journalPaths=Object.freeze([
 '/private/tmp/studiquo-rag-policy-v1-20261014-01/journal.ndjson',
 '/private/tmp/studiquo-rag-policy-dedup-20261014-01/journal.ndjson',
 '/private/tmp/studiquo-rag-policy-current-20261014-01/journal.ndjson',
 '/private/tmp/studiquo-rag-policy-partial-only-20261014-01/journal.ndjson',
]);
const delta=Object.freeze({subjects:[{aliases:['合成灯F','F']},{aliases:['合成灯E','E']}],
 attribute:'recorded lighting duration',amount:2,unit:'時間',relation:'longer',permission:'allowed'});

export function replayAnswerCoverage() {
 const prior=JSON.parse(fs.readFileSync(new URL('../../../docs/RAG_POLICY_REVISION_RESULTS.json',import.meta.url),'utf8') as any);
 const annotations=JSON.parse(fs.readFileSync(new URL('./answer-coverage-reviews.json',import.meta.url),'utf8') as any);
 if(prior.syntheticOnly!==true||prior.variants.length!==4||annotations.version!==1||annotations.annotations.length!==8)throw Error('invalid_coverage_fixture');
 const contracts=developmentCoverageContracts(),used=new Set(),rows=[];
 for(const [i,v] of prior.variants.entries()) {
  if(v.journal!==journalPaths[i])throw Error('unexpected_coverage_journal');
  const st=fs.lstatSync(v.journal);
  if(!st.isFile()||st.isSymbolicLink()||st.size>8*1024*1024)throw Error('invalid_coverage_journal');
  const raw=fs.readFileSync(v.journal,'utf8');
  if(hash(raw)!==v.journalHash)throw Error('coverage_journal_changed');
  const records=raw.trim().split('\n').map(JSON.parse);let previous=null;
  for(const r of records){if(r.previous!==previous)throw Error('coverage_journal_corrupt');previous=hash(JSON.stringify(r));}
  const states=new Map();for(const r of records.slice(1))states.set(r.id,r.type);
  if(states.size!==6||[...states.values()].some(s=>s!=='completed'))throw Error('unresolved_coverage_journal');
  for(const record of records.filter(r=>r.type==='completed'&&r.id.startsWith('e50-partial-03:'))) {
   const a=annotations.annotations.find((a: any)=>a.variant===v.variant&&a.id===record.id);
   const identity=v.variant+':'+record.id;
   if(!a||used.has(identity)||hash(record.answer)!==a.answerHash||!['satisfied','omitted'].includes(a.state))throw Error('invalid_coverage_annotation');
   used.add(identity);
   const style=record.id.split(':')[1],contract=contracts.find((c: any)=>c.caseId==='e50-partial-03'&&c.style===style);
   let quotes: any[]=[];
   if(a.quote){const text=record.answer.slice(a.quote.start,a.quote.end);if(hash(text)!==a.quote.hash)throw Error('coverage_quote_changed');quotes=[{start:a.quote.start,end:a.quote.end,text}];}
   const reviewed=reviewCoverage(contract,record.answer,{reviewer:{kind:'independent_ai',id:'fixed-delta-review-20261014'},
    answerHash:coverageHash(record.answer),contractHash:coverageHash(contract),
    rows:[{id:'claim:c1',state:a.state,quotes,...(a.scan?{scan:a.scan,reasonCode:a.reasonCode}:{})}]});
   rows.push({variant:v.variant,id:record.id,answerHash:a.answerHash,
    probe:probeExplicitDifference(record.answer,delta),reviewed:reviewed.rows.find((r: any)=>r.id==='claim:c1').state,
    reviewHash:coverageHash(reviewed),otherRequirementsPending:reviewed.counts.pending,
    contentAccepted:reviewed.contentAccepted,releaseAccepted:reviewed.releaseAccepted});
  }
 }
 if(used.size!==8)throw Error('incomplete_coverage_annotations');
 return {version:1,syntheticOnly:true,externalCalls:0,priorReportHash:coverageHash(prior),
  annotationHash:coverageHash(annotations),developmentQuestions:30,styleContracts:contracts.length,
  reusedAnswers:24,deltaReviewedAnswers:rows.length,rows,
  counts:{satisfied:rows.filter(r=>r.reviewed==='satisfied').length,omitted:rows.filter(r=>r.reviewed==='omitted').length,
   explicitCandidates:rows.filter(r=>r.probe.candidate==='explicit_candidate').length,
   omissionCandidates:rows.filter(r=>r.probe.candidate==='omission_candidate').length,
   needsReview:rows.filter(r=>r.probe.candidate==='needs_review').length},
  limitation:'finite syntax diagnostic plus reviewer-supplied annotations, not semantic automatic grading or runtime prevention'};
}

if(process.argv[1]&&import.meta.url===pathToFileURL(path.resolve(process.argv[1])).href) {
 try{console.log(JSON.stringify(replayAnswerCoverage(),null,2));}
 catch{console.error('coverage_replay_failed');process.exitCode=1;}
}
