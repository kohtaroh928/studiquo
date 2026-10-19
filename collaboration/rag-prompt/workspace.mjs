// Offline preparation only. No credential access, provider SDK, fetch or model execution.
import {readFileSync, mkdirSync, writeFileSync} from 'node:fs';
import {fileURLToPath, pathToFileURL} from 'node:url';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {loadPromptBaseline, baselinePolicyPair} from '../../mcp-server/scripts/rag-quality/prompt-baseline.mjs';

const root = fileURLToPath(new URL('./', import.meta.url));
const hash = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
export function validateCandidate(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value) ||
      Object.keys(value).sort().join(',') !== 'additionalInstructions,baselineId,id,version' ||
      value.version !== 1 || value.baselineId !== '20261014-policy-v1' ||
      typeof value.id !== 'string' || !/^[a-z][a-z0-9-]{0,63}$/.test(value.id) ||
      typeof value.additionalInstructions !== 'string' ||
      !value.additionalInstructions.trim() || Buffer.byteLength(value.additionalInstructions) > 16384) {
    throw Error('invalid_candidate');
  }
  return value;
}
// Smoke check, not proof: it catches an appended instruction that openly tells
// the model to drop the frozen safety rules. A human review still decides.
const UNSAFE_INSTRUCTION = [
  /\b(?:ignore|disregard|forget)\s+(?:all\s+|any\s+|the\s+)?(?:previous|prior|above|earlier|system|safety)\b/i,
  /\boverride\s+(?:the\s+)?(?:rules?|polic(?:y|ies)|instructions?|safety)\b/i,
  /(?:指示|ルール|規則|方針|制約|安全).{0,12}(?:無視|破棄|上書き|解除)/u,
  /従わ(?:なくて|なく)(?:も)?(?:よい|良い|いい|構いません)/u,
  /(?:資料|参考データ|抜粋).{0,12}(?:指示|命令).{0,8}(?:に従って|に従い|を実行)/u,
];
export function assertSafeInstructions(candidate) {
  if (UNSAFE_INSTRUCTION.some(pattern => pattern.test(candidate.additionalInstructions))) throw Error('unsafe_candidate');
}
export function preparePacket(candidate) {
  validateCandidate(candidate);
  assertSafeInstructions(candidate);
  const {manifest, contexts} = loadPromptBaseline();
  const pairs = contexts.flatMap(row => ['source_only', 'explain'].map(style => {
    const baseline = baselinePolicyPair(row.key, style).original;
    const proposed = {...structuredClone(baseline),
      instructions: baseline.instructions + '\n\n' + candidate.additionalInstructions};
    // The frozen rules stay byte-for-byte first; a candidate may only append.
    if (!proposed.instructions.startsWith(baseline.instructions)) throw Error('unsafe_candidate');
    return {caseKey:row.key, style, status:row.status,
      baseline, candidate:proposed, citations:structuredClone(row.citations),
      baselineHash:hash(baseline), candidateHash:hash(proposed)};
  }));
  return {version:1, syntheticOnly:true, baselineId:manifest.id,
    candidateId:candidate.id, candidateHash:hash(candidate),
    contextsHash:manifest.contextsHash, externalCalls:0,
    comparison:'frozen historical baseline plus appended candidate instructions; not current-production or live-retrieval evaluation',
    pairs};
}
export function summary(packet) {
  return {baselineId:packet.baselineId, candidateId:packet.candidateId,
    candidateHash:packet.candidateHash, contextsHash:packet.contextsHash,
    syntheticOnly:true, contexts:packet.pairs.length / 2, pairedCases:packet.pairs.length,
    externalCalls:0, qualityVerdict:'not_evaluated'};
}
function main(args) {
  const [command='check', candidateName='example', runName] = args;
  if (!['check','prepare'].includes(command) || args.length > 3 ||
      !/^[a-z][a-z0-9-]{0,63}$/.test(candidateName) ||
      (command === 'check' && runName !== undefined) ||
      (command === 'prepare' && (!runName || !/^[a-z][a-z0-9-]{0,63}$/.test(runName)))) {
    throw Error('usage: check [candidate-name] | prepare candidate-name new-run-name');
  }
  if (Number(process.versions.node.split('.')[0]) < 24) throw Error('node_24_required');
  const packet = preparePacket(JSON.parse(readFileSync(path.join(root, 'candidates', candidateName+'.json'), 'utf8')));
  if (command === 'prepare') {
    // A new run directory only. Never replaces an old comparison or accepts arbitrary output paths.
    const outputRoot = path.join(root, '.local');
    mkdirSync(outputRoot, {recursive:true, mode:0o700});
    const output = path.join(outputRoot, runName);
    mkdirSync(output, {mode:0o700});
    writeFileSync(path.join(output,'pairs.json'), JSON.stringify(packet,null,2)+'\n', {flag:'wx',mode:0o600});
    const review = {version:1, candidateHash:packet.candidateHash, reviewer:null,
      generation:{provider:null, model:null, settings:null, authorizedBudget:null, actualCalls:0},
      rows:packet.pairs.map(p=>({caseKey:p.caseKey,style:p.style,baselineHash:p.baselineHash,
        candidateHash:p.candidateHash, baselineAnswerHash:null,candidateAnswerHash:null,
        requiredItems:[], findings:[], verdict:'pending'})),
      limitation:'Fill atomic requirements and independent evidence-based review; empty rows are not passes. Do not send gold to generator.'};
    writeFileSync(path.join(output,'review.json'),JSON.stringify(review,null,2)+'\n',{flag:'wx',mode:0o600});
  }
  console.log(JSON.stringify(summary(packet)));
}
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {main(process.argv.slice(2));}
  catch {console.error('rag_prompt_workspace_failed: check Node 24+, candidate JSON, frozen files and a new run name; no model was called');process.exitCode=1;}
}
