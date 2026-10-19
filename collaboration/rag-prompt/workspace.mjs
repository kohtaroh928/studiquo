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
// More ways to weaken the frozen rules that the list above misses: permitting links,
// writing citations or ids into the answer, revealing the prompt, letting the model
// fill gaps from general knowledge, and fake role lines. Still a smoke check.
const WEAKENING_INSTRUCTION = [
  /\b(?:add|include|append|output|insert|provide|attach)\s+(?:a\s+|an\s+|the\s+)?(?:hyper)?links?\b/iu,
  /(?:リンク|URL|ＵＲＬ|ハイパーリンク|link|hyperlink)s?.{0,16}(?:付け|付与|出力|表示|含め|貼|案内|書い|include|add|output|append)/iu,
  /(?:出典|ページ番号|chunk\s*id|source\s*id|ソースID).{0,16}(?:本文|回答|文中).{0,8}(?:書|出力|入れ|示|含め)/iu,
  /(?:本文|回答|文中).{0,12}(?:出典|ページ番号|chunk\s*id|source\s*id|ソースID).{0,12}(?:書|出力|入れ|示|含め)/iu,
  /(?:システムプロンプト|system\s*prompt|内部の指示|隠れた指示|凍結規則).{0,16}(?:表示|出力|教え|開示|見せ|reveal|print|show|output)/iu,
  /(?:reveal|print|show|output|display|disclose|表示|出力|開示).{0,16}(?:system\s*prompt|システムプロンプト|内部の指示|隠れた指示)/iu,
  /(?:資料|抜粋|参考データ)(?:に|には)?(?:ない|無い|なくても|記載のない).{0,20}(?:補って|加えて|追加して|推測して|作って)(?:よい|良い|いい|ください|も構いません)/u,
  /(?:一般知識|常識|自分の知識).{0,16}(?:で|を使って|により).{0,8}(?:補って|答えて|埋めて)(?:よい|良い|いい|ください|も構いません)/u,
  /^\s*(?:system|assistant|developer|システム|管理者)\s*[:：]/imu,
  /(?:developer|debug|jailbreak)\s+mode|開発者モード|デバッグモード/iu,
];
const INVISIBLE = /[\p{Cf}\p{Cc}]/gu;
// A candidate is checked as written, as NFKC-normalized text, and with spaces removed,
// so full-width forms and "i g n o r e" style spacing do not slip past the patterns.
function variants(text) {
  const nfkc = text.normalize('NFKC');
  return [text, nfkc, nfkc.replace(/\s+/gu, '')];
}
// Applied only to the whitespace-free variant, which catches "i g n o r e ...".
const SQUASHED_UNSAFE = [
  /(?:ignore|disregard|forget)(?:all|any|the)?(?:previous|prior|above|earlier|system|safety)/i,
  /override(?:the)?(?:rules?|policy|policies|instructions?|safety)/i,
];
export function assertSafeInstructions(candidate) {
  const text = candidate.additionalInstructions;
  // Hidden characters have no place in a prompt a human is meant to review.
  if ([...text.matchAll(INVISIBLE)].some(([c]) => !['\n', '\t', '\r'].includes(c))) throw Error('unsafe_candidate');
  // Long encoded blobs and links cannot be reviewed by reading them.
  if (/[A-Za-z0-9+/=]{200,}/u.test(text) || /https?:\/\/|\]\(/iu.test(text.normalize('NFKC'))) throw Error('unsafe_candidate');
  const [, , squashed] = variants(text);
  if (variants(text).some(v => UNSAFE_INSTRUCTION.some(pattern => pattern.test(v))) || SQUASHED_UNSAFE.some(pattern => pattern.test(squashed))) throw Error('unsafe_candidate');
  // "Do not write links" tightens the rules; "write links" loosens them. The patterns
  // above match both, so a negation in or right after the match clears it.
  const negated = /ない|ず(?:に)?|禁止|避け|\bnot\b|\bnever\b|n't|\bwithout\b|\bno\b/iu;
  // "資料にない…" names the gap the instruction wants filled, it is not a prohibition.
  const gapPhrase = /(?:資料|抜粋|参考データ)(?:に|には)?(?:ない|無い|なくても)|記載のない/gu;
  const weakens = v => WEAKENING_INSTRUCTION.some(pattern => {
    const m = pattern.exec(v);
    return m && !negated.test(v.slice(m.index, m.index + m[0].length + 12).replace(gapPhrase, ''));
  });
  if (variants(text).some(weakens)) throw Error('unsafe_candidate');
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
