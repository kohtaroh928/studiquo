// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
// Evaluation only: gold/checklists never enter a generation request.
// This module validates review evidence, not semantic entailment.
import {createHash} from 'node:crypto';
import {loadEvaluation50, validateEvaluation50, answerProbeInput} from './evaluation-50.ts';
export const coverageHash = (value: any) => createHash('sha256').update(JSON.stringify(value)).digest('hex');
const states = ['satisfied','omitted','incorrect','unsupported','pending','not_applicable'];
const styles = ['source_only','explain'];

export function developmentCoverageContracts(bank = loadEvaluation50()) {
 validateEvaluation50(bank);
 return bank.cases.filter((c: any) => c.split === 'development').flatMap((c: any) => styles.map(style => ({
  version:1,caseId:c.id,style,inputHash:coverageHash(answerProbeInput(c)),bankHash:coverageHash(bank),rubricVersion:bank.rubricVersion,goldReview:'pending',
  requirements:[
   ...c.claims.map((claim: any) => ({id:'claim:'+claim.id,origin:'existing_gold',applicability:'required',kind:claim.kind,dimension:claim.dimension,
    expected:claim.expected,evidence:structuredClone(claim.evidence)})),
   ...bank.commonChecks.map((expected: any,i: any) => ({id:'common:'+i,origin:'common_rubric',applicability:'review',kind:'policy',expected})),
   ...bank.styleChecks[style].map((expected: any,i: any) => ({id:'style:'+i,origin:'style_rubric',applicability:'review',kind:'policy',expected})),
   ...c.forbiddenClaims.map((expected: any,i: any) => ({id:'forbidden:'+i,origin:'forbidden_claim',applicability:'required',kind:'prohibition',expected})),
  ],
 })));
}

export function reviewCoverage(contract: any, answer: any, review = {rows:[]}) {
 const fail = () => {throw Error('invalid_coverage_review');};
 if(!contract || contract.version!==1 || !styles.includes(contract.style) || !Array.isArray(contract.requirements) ||
    !contract.requirements.length || contract.requirements.length>128 ||
    typeof answer!=='string' || Buffer.byteLength(answer)>65536 || !Array.isArray(review?.rows)) fail();
 const ids=new Set(),requirements=new Map();
 for(const r of contract.requirements) {
  if(typeof r.id!=='string'||!r.id||ids.has(r.id)||typeof r.expected!=='string'||!r.expected)fail();
  if(!['required','review'].includes(r.applicability))fail();
  ids.add(r.id);requirements.set(r.id,r);
 }
 if(review.rows.length && (!['human','independent_ai'].includes(review.reviewer?.kind)||
    typeof review.reviewer?.id!=='string'||!review.reviewer.id||review.reviewer.id.length>100||
    review.answerHash!==coverageHash(answer)||review.contractHash!==coverageHash(contract)))fail();
 const submitted=new Map();
 for(const row of review.rows) {
  if(!ids.has(row.id)||submitted.has(row.id)||!states.includes(row.state)||!Array.isArray(row.quotes))fail();
  const requirement=requirements.get(row.id),scan=row.scan?.start===0&&row.scan?.end===answer.length;
  const absencePass=row.state==='satisfied'&&['policy','prohibition'].includes(requirement.kind)&&!row.quotes.length;
  if(['satisfied','incorrect','unsupported'].includes(row.state)&&!row.quotes.length&&!absencePass)fail();
  if(['omitted','not_applicable'].includes(row.state)&&row.quotes.length)fail();
  if(row.state==='not_applicable'&&requirement.applicability!=='review')fail();
  if((['omitted','not_applicable'].includes(row.state)||absencePass)&&(!scan||
     !['not_stated','no_background_added','not_relevant_to_question','full_answer_prohibition_check','no_formula_requested'].includes(row.reasonCode)))fail();
  if(row.quotes.length>8)fail();
  for(const q of row.quotes) {
   if(!Number.isSafeInteger(q.start)||!Number.isSafeInteger(q.end)||q.start<0||q.end<=q.start||q.end>answer.length||
      typeof q.text!=='string'||q.text.length>4096||answer.slice(q.start,q.end)!==q.text)fail();
  }
  submitted.set(row.id,row);
 }
 const rows=contract.requirements.map((r: any) => {
  const d=submitted.get(r.id);
  return {id:r.id,state:d?.state??'pending',quoteHashes:(d?.quotes??[]).map(coverageHash),
   ...(d?.scan?{scan:structuredClone(d.scan)}:{}),...(d?.reasonCode?{reasonCode:d.reasonCode}:{})};
 });
 const counts=Object.fromEntries(states.map(s=>[s,rows.filter((r: any)=>r.state===s).length]));
 // Conditional rubric checks need an explicit applicability decision. Gold
 // claims cannot be hidden as N/A. Quotes/scans are provenance, not entailment.
 return {contractHash:coverageHash(contract),answerHash:coverageHash(answer),rows,counts,
  addressedCount:counts.satisfied+counts.incorrect+counts.unsupported,
  complete:counts.pending===0,contentAccepted:counts.pending===0&&counts.omitted===0&&counts.incorrect===0&&counts.unsupported===0&&counts.satisfied>0,
  ...(review.reviewer?{reviewerKind:review.reviewer.kind,reviewerHash:coverageHash(review.reviewer)}:{}),
  releaseAccepted:false,goldReview:contract.goldReview??'pending',semanticAuthority:'reviewer_supplied_not_machine_verified'};
}

const escape = (s: any) => s.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
const relations: any={longer:'長',shorter:'短',higher:'高',cheaper:'安',more:'多',fewer:'少',later:'遅',earlier:'早'};

// Finite Japanese diagnostic, not a grader. Even a positive is not a pass.
// Subjects, attribute, value, unit and comparison permission come from a
// separately reviewed evaluation contract, never inferred from product names.
export function probeExplicitDifference(answer: any, requirement: any) {
 const result=(candidate: any,reason: any)=>({candidate,reason,authoritative:false});
 const r=requirement;
 if(typeof answer!=='string'||!r||!Array.isArray(r.subjects)||r.subjects.length!==2||
    !r.subjects.every((s: any)=>Array.isArray(s.aliases)&&s.aliases.length>0&&s.aliases.length<=4&&s.aliases.every((a: any)=>typeof a==='string'&&a.length>0&&a.length<=100))||
    !Number.isSafeInteger(r.amount)||r.amount<=0||r.amount>1000000||!Object.hasOwn(relations,r.relation)||
    typeof r.unit!=='string'||!['時間','分','秒','日','円','個','kg','cm'].includes(r.unit))throw Error('invalid_difference_requirement');
 if(Buffer.byteLength(answer)>65536)return result('needs_review','answer_limit');
 if(r.permission!=='allowed')return result('needs_review','comparison_not_authorized_by_contract');
 if(!answer.trim())return result('omission_candidate','empty_answer');
 const alias=(s: any)=>s.aliases.map((a: any)=>/^[A-Za-z0-9_]+$/.test(a)?`(?<![A-Za-z0-9_])${escape(a)}(?![A-Za-z0-9_])`:escape(a)).join('|');
 const [winner,other]=r.subjects.map((s: any)=>`(?:${alias(s)})`);
 if(!new RegExp(winner,'u').test(answer)||!new RegExp(other,'u').test(answer))return result('needs_review','subject_not_explicit');
 // Conservative exclusions. Syntax outside this finite form needs review;
 // quoted instructions, corrections or hypothetical examples are not proof.
 if(/[「」『』`|\t]|system\s*:|role\s*:|仮定|たとえば|例えば|かもしれ|誤り|誤記|間違|約\s*\d|およそ|もし|なら|場合/i.test(answer))return result('needs_review','quoted_or_uncertain_statement');
 const predicate=relations[r.relation];
 const pattern=new RegExp(`${winner}(?:の(?:方|ほう))?(?:が|は)\\s*(?:${other}(?:より|に比べて)\\s*)?${r.amount}${escape(r.unit)}${predicate}(?:い|く)`,'gu');
 const matches=[...answer.matchAll(pattern)];
 if(matches.length) {
  if([...answer.matchAll(new RegExp(`\\d+${escape(r.unit)}(?:長|短|高|安|多|少|遅|早)`,'gu'))].length>1)return result('needs_review','multiple_relation_candidates');
  for(const m of matches) {
   const suffix=answer.slice(m.index+m[0].length,m.index+m[0].length+24);
   if(/^(?:ない|はない|ありません|はありません|とは|わけ|と言えない|という(?:意味|記載|こと)では)/.test(suffix))return result('needs_review','negated_or_qualified_relation');
   if(!/^(?:(?:です|である|だ)(?:が)?|ですが)?(?:[。、，,.!！\n\s]|$)/.test(suffix))return result('needs_review','non_assertive_or_unknown_tail');
  }
  const reversed=new RegExp(`${other}(?:の(?:方|ほう))?(?:が|は)(?:${winner}より)?(?:\\d+${escape(r.unit)})?${predicate}い`,'u');
  if(reversed.test(answer))return result('needs_review','conflicting_direction_candidate');
  return result('explicit_candidate','finite_relation_pattern');
 }
 // Unknown paraphrases, arithmetic notation, wrong direction or wrong amount
 // are not silently called omissions or accepted by numeral co-occurrence.
 if(/差|長|短|高|安|多|少|遅|早|より|比べ|倍|上回|下回|余分|隔たり|増加|減少|[=＝−-]|longer|shorter|more|less/i.test(answer)||new RegExp(`${r.amount}${escape(r.unit)}`,'u').test(answer))return result('needs_review','relation_requires_semantic_review');
 return result('omission_candidate','no_explicit_relation_candidate');
}
