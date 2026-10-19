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
  // Cancelling or voiding the rules without the words "ignore"/"override" (no negation can excuse these).
  /\b(?:stop|quit|cease)\s+(?:obeying|following|respecting)\b/iu,
  /\b(?:rules?|instructions?|polic(?:y|ies)|guidelines?)\b.{0,30}\b(?:void|invalid|no longer apply|do(?:es)? not apply|(?:are|is) (?:cancel(?:l)?ed|revoked|replaced|lifted))/iu,
  /\btreat\s+(?:the\s+)?(?:rules?|instructions?|polic(?:y|ies))\b.{0,12}\bas\s+(?:void|invalid|null)/iu,
  /\bdisregard\s+everything\b|\bpay\s+no\s+attention\s+to\b/iu,
  /\byou\s+are\s+now\s+(?:an?\s+)?(?:unrestricted|unfiltered|jailbroken|different|new)\b/iu,
  /(?:これまで|以前|上記|前|先)の(?:ルール|規則|方針|指示|制約).{0,10}(?:適用しない|適用外|無効|効力を失|なかったこと)/u,
  /(?:資料|抜粋|参考データ)(?:内|中)の(?:依頼|要求|指示|命令).{0,12}(?:実行|従)/u,
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
  // Own knowledge to fill gaps, links/addresses, ids, and asking for the hidden prompt.
  /\b(?:fill|make)\s+(?:in|up)\b.{0,30}\b(?:own|your)\s+(?:knowledge|training)|\buse\s+your\s+(?:own\s+)?(?:training\s+data|knowledge|memory)\b/iu,
  /(?:URL|ＵＲＬ|サイト|アドレス|リンク|link|url)s?.{0,12}(?:必ず|かならず|always)?.{0,6}(?:含め|書|付け|載せ|貼|案内|include|add|write|append)/iu,
  /\b(?:quote|include|write|cite|print|add)\b.{0,24}\b(?:chunk|source)\s*(?:id|identifier)s?\b|(?:出典|ソース|チャンク)\s*ID.{0,10}(?:付け|書|含め|載せ|入れ)/iu,
  /\b(?:reference|source)\s+(?:link|url)s?\b/iu,
  /\b(?:tell|show|give)\s+me\b.{0,24}\b(?:hidden|initial|original|system|first)\s+instructions?\b|(?:最初|初め|はじめ)に(?:受けた|与えられた)指示.{0,12}(?:教え|表示|出力|見せ|そのまま)/iu,
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
  // above match both, so a negation in the same sentence clears the match. "must" or
  // "必ず" are not negations, and "do not forget" asks for the thing, it does not forbid it.
  const negated = /ない|(?<!必)ず(?:に|、)?|禁止|避け|ません|いけ|てはなら|(?:do|does|must|should|shall|will|can)\s*not\b|\bnever\b|n't|\bwithout\b|\bno\s+(?:links?|urls?|ids?)\b/iu;
  const notAnObjection = /(?:do\s*not|don't)\s+forget/giu;
  // "資料にない…" names the gap the instruction wants filled, it is not a prohibition.
  const gapPhrase = /(?:資料|抜粋|参考データ)(?:に|には)?(?:ない|無い|なくても)|記載のない/gu;
  const sentenceEnd = /[。.!?！？\n]/u;
  const weakens = v => WEAKENING_INSTRUCTION.some(pattern => {
    const global = new RegExp(pattern.source, pattern.flags.includes('g') ? pattern.flags : pattern.flags + 'g');
    return [...v.matchAll(global)].some(m => {
      const from = m.index, matchEnd = m.index + m[0].length;
      const tail = v.slice(matchEnd);
      const stop = tail.search(sentenceEnd);
      // The whole sentence the match sits in: "Never add a link" negates from before the match.
      const before = v.slice(0, from).split(sentenceEnd).at(-1) ?? '';
      const clause = (before + v.slice(from, stop < 0 ? v.length : matchEnd + stop)).replace(gapPhrase, '').replace(notAnObjection, '');
      return !negated.test(clause);
    });
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
