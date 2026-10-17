// Offline, synthetic-only comparison support. Never sends requests or reads credentials.
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {pathToFileURL} from 'node:url';
import path from 'node:path';
import {ragAnswerPolicy} from '../../src/rag/answer-policy.js';
import {ragAnswerPolicy as frozenPolicy} from './baselines/20261014-policy-v1/answer-policy.mjs';

const directory = new URL('./baselines/20261014-policy-v1/', import.meta.url);
export const baselineHash = value => createHash('sha256').update(value).digest('hex');
const jsonHash = value => baselineHash(JSON.stringify(value));
export function loadPromptBaseline() {
 const manifest = JSON.parse(readFileSync(new URL('manifest.json', directory), 'utf8'));
 const contexts = JSON.parse(readFileSync(new URL('production-contexts.json', directory), 'utf8'));
 const rubric = readFileSync(new URL('rubric.md', directory), 'utf8');
 if (manifest.version !== 1 || manifest.syntheticOnly !== true ||
     baselineHash(readFileSync(new URL('answer-policy.mjs', directory))) !== manifest.frozenPolicyHash ||
     jsonHash(contexts) !== manifest.contextsHash ||
     baselineHash(rubric) !== manifest.rubric.hash) throw Error('prompt_baseline_corrupt');
 for (const row of manifest.policies) {
  if (baselineHash(frozenPolicy(row.status, row.style)) !== row.hash) throw Error('prompt_baseline_corrupt');
 }
 return {manifest, contexts, rubric};
}

// The two bodies have exactly the same question/history/context/configuration.
// Only the final fixed policy changes. No gold or grader is added to either body.
// These bodies are NOT accepted handles for the live runner. A separate reviewed
// adapter is needed before using them for a paid comparison.
export function baselinePolicyPair(caseKey, style) {
 if (!['source_only', 'explain'].includes(style)) throw Error('invalid_baseline_style');
 const {contexts} = loadPromptBaseline();
 const row = contexts.find(c => c.key === caseKey);
 if (!row) throw Error('invalid_baseline_case');
 const original = {...structuredClone(row.body), instructions: row.baseInstructions + frozenPolicy(row.status, style)};
 const candidate = {...structuredClone(row.body), instructions: row.baseInstructions + ragAnswerPolicy(row.status, style)};
 return {original, candidate, citations: structuredClone(row.citations), status: row.status};
}

export function promptBaselineReport() {
 const {manifest, contexts} = loadPromptBaseline();
 const changedFiles = manifest.sources.filter(row =>
  baselineHash(readFileSync(new URL('../../' + row.path, import.meta.url))) !== row.hash
 ).map(row => row.path);
 const changedEvaluationFiles = [manifest.rubric, ...manifest.priorResults].filter(row =>
  baselineHash(readFileSync(new URL('../../../' + row.path, import.meta.url))) !== row.hash
 ).map(row => row.path);
 return {baselineId: manifest.id, syntheticOnly: true, externalCalls: 0,
  frozenPolicies: manifest.policies.length, frozenContexts: contexts.length,
  changedFiles, changedEvaluationFiles, policies: manifest.policies.map(row => {
   const current = ragAnswerPolicy(row.status, row.style);
   return {...row, currentHash: baselineHash(current), changed: baselineHash(current) !== row.hash,
    currentBytes: Buffer.byteLength(current)};
  })};
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
 try {console.log(JSON.stringify(promptBaselineReport()));}
 catch {console.error('prompt_baseline_verification_failed'); process.exitCode = 1;}
}
