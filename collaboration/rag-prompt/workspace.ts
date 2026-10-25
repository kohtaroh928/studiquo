// Offline preparation only. No credential access, provider SDK, fetch or model execution.
import {readFileSync, mkdirSync, writeFileSync} from 'node:fs';
import {fileURLToPath, pathToFileURL} from 'node:url';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {loadPromptBaseline, baselinePolicyPair} from '../../mcp-server/scripts/rag-quality/prompt-baseline.ts';

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
  /\b(?:ignore|disregard)\s+(?:all\s+|any\s+|the\s+|these\s+|those\s+)?(?:rules?|instructions?|guidelines?|polic(?:y|ies))\b/i,
  /\bignore\s+what\s+(?:the\s+)?(?:documents?|references?|sources?|excerpts?)\s+(?:say|state|contain|show)\b/i,
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
  // Dropping or forgetting the rules in other words (found by the second security review).
  /\b(?:don'?t|do not|never)\s+(?:follow|obey|respect)\s+(?:the\s+)?(?:rules?|instructions?|guidelines?|polic(?:y|ies))\s+(?:above|given|before|earlier|previous|prior|so far)\b/iu,
  /\bforget\s+(?:the\s+|your\s+|all\s+|any\s+)?(?:guidelines?|rules?|instructions?|polic(?:y|ies)|safety)\b/iu,
  /\b(?:drop|bypass|circumvent|disable|remove|lift|turn\s+off|switch\s+off|get\s+around)\s+(?:the\s+|all\s+|your\s+)?(?:safety\s+|safe\s+)?(?:rules?|guardrails?|safeguards?|filters?|restrictions?|guidelines?|polic(?:y|ies))\b/iu,
  /\b(?:rules?|instructions?|guidelines?)\b[^.]{0,30}\b(?:obsolete|superseded|deprecated|outdated|overridden|replaced|void|moot)\b/iu,
  /\bpretend\b[^.]{0,30}\b(?:rules?|instructions?|guidelines?)\b[^.]{0,20}\b(?:do(?:es)?\s+not|don'?t|never)\s+exist/iu,
  /\bact\s+as\s+(?:an?\s+)?(?:unrestricted|unfiltered|jailbroken|evil)\b/iu,
  /\bDAN\b/u,
  /\b(?:print|repeat|output|recite|display)\s+(?:everything|all\s+text|all|the\s+text|your\s+(?:instructions|prompt))\s+(?:above|before|so\s+far)\b/iu,
  /(?:新しい|別の)役割.{0,10}(?:制限なく|制限のない|何でも|自由に)|制限(?:なく|のない|を外|を解除)/u,
  /(?:指示|ルール|規則|方針|制約|安全規則|安全ルール).{0,12}(?:忘れ|外し|外して|取り払|なくし)/u,
  // Third security review: more ways to say "stop checking the references".
  /\b(?:may|can|could|are\s+allowed\s+to|feel\s+free\s+to)\s+(?:ignore|disregard|skip)\s+(?:the\s+)?(?:references?|sources?|excerpts?|documents?)\b/iu,
  /\bignore\s+(?:everything|all|anything)\b/iu,
  /\bact\s+without\s+(?:any\s+)?(?:restrictions?|limits?|rules)\b/iu,
  /\bnever\s+(?:say|admit|state)\s+(?:that\s+)?you\s+(?:don'?t|do\s+not)\s+know\b/iu,
  /\balways\s+answer\b.{0,30}\b(?:even\s+when|even\s+if|regardless)\b/iu,
  /\bno\s+longer\s+in\s+effect\b/iu,
  // A double negative that permits what the rules forbid.
  /(?:リンク|URL|ＵＲＬ|出典\s*ID|ソース\s*ID).{0,6}(?:禁止|制限|規制)しない/iu,
  /(?:資料|参考資料|抜粋).{0,6}(?:に頼らず|を無視|を見ずに|なしで).{0,16}(?:答え|回答)/u,
  /(?:ルール|規則|方針|指示).{0,6}(?:守らなく|従わなく)(?:て|ても)?(?:構いません|よい|いい)/u,
];
// More ways to weaken the frozen rules that the list above misses: permitting links,
// writing citations or ids into the answer, revealing the prompt, letting the model
// fill gaps from general knowledge, and fake role lines. Still a smoke check.
const WEAKENING_INSTRUCTION = [
  /\b(?:add|include|append|output|insert|provide|attach)\s+(?:a\s+|an\s+|the\s+|any\s+|some\s+)?(?:reference\s+|source\s+)?(?:hyper)?links?\b/iu,
  /(?:リンク|URL|ＵＲＬ|ハイパーリンク|link|hyperlink)s?.{0,16}(?:付け|付与|出力|表示|含め|貼|案内|書い|入れ|挿入|記載|示し|添え|併記|include|add|output|append)/iu,
  /(?:出典|ページ番号|chunk\s*id|source\s*id|ソースID).{0,16}(?:本文|回答|文中).{0,8}(?:書|出力|入れ|示|含め)/iu,
  /(?:本文|回答|文中).{0,12}(?:出典|ページ番号|chunk\s*id|source\s*id|ソースID).{0,12}(?:書|出力|入れ|示|含め)/iu,
  /(?:システムプロンプト|system\s*prompt|内部の指示|隠れた指示|凍結規則).{0,16}(?:表示|出力|教え|開示|見せ|reveal|print|show|output)/iu,
  /(?:reveal|print|show|output|display|disclose|表示|出力|開示).{0,16}(?:system\s*prompt|システムプロンプト|内部の指示|隠れた指示)/iu,
  /(?:資料|抜粋|参考データ)(?:に|には)?(?:ない|無い|なくても|記載のない).{0,20}(?:補って|加えて|追加して|推測して|作って)(?:よい|良い|いい|ください|も構いません)/u,
  /(?:一般知識|常識|自分の知識).{0,16}(?:で|を使って|により).{0,8}(?:補って|答えて|埋めて)(?:よい|良い|いい|ください|も構いません)/u,
  /^\s*(?:system|assistant|developer|システム|管理者)\s*[:：]/imu,
  /(?:developer|debug|jailbreak)\s+mode|開発者モード|デバッグモード/iu,
  // Own knowledge to fill gaps, links/addresses, ids, and asking for the hidden prompt.
  /\b(?:fill|make)\s+(?:in|up)\b.{0,30}\b(?:own|your)\s+(?:knowledge|training)|\buse\s+your\s+(?:own\s+)?(?:training\s+data|knowledge|memory)\b.{0,40}\b(?:fill|instead|when|if|beyond|outside|supplement|to\s+answer)\b/iu,
  /(?:URL|ＵＲＬ|サイト|アドレス|リンク|link|url)s?.{0,12}(?:必ず|かならず|always)?.{0,6}(?:含め|書|付け|載せ|貼|案内|include|add|write|append)/iu,
  /\b(?:quote|include|write|cite|print|add)\b.{0,24}\b(?:chunk|source)\s*(?:id|identifier)s?\b|(?:出典|ソース|チャンク)\s*ID.{0,10}(?:付け|書|含め|載せ|入れ|添え|併記)/iu,
  /\b(?:reference|source)\s+(?:link|url)s?\b/iu,
  /\b(?:outside|external|your\s+own)\s+knowledge\b/iu,
  /\b(?:offer|give|share|list|show|provide)\s+(?:the\s+|any\s+|some\s+)?(?:links?|urls?)\b/iu,
  /\b(?:answer|respond)\s+freely\b|\bfrom\s+(?:your\s+)?(?:background|general|prior)\s+knowledge\b/iu,
  /\b(?:respond\s+with|append|add|put|include|write)\b.{0,24}\b(?:urls?|web\s*address|document\s*id|page\s*number|identifier)\b/iu,
  /(?:元の|最初の|初期の|内部の|隠れた|システムの)指示.{0,10}(?:全文|そのまま)?.{0,4}(?:表示|出力|教え|見せ|開示)/u,
  /\b(?:reveal|show|print|display|disclose|repeat)\s+(?:me\s+)?(?:your|the|all|these)\s+(?:instructions?|prompt|rules)\b/iu,
  /(?:開発者|システム|developer)\s*メッセージ.{0,6}(?:表示|出力|教え|見せ)/iu,
  /(?:上|前|先)(?:の|記の)?(?:テキスト|文章|内容|指示).{0,8}(?:繰り返|復唱|そのまま出力|表示)/u,
  /\b(?:tell|show|give)\s+me\b.{0,24}\b(?:hidden|initial|original|system|first)\s+instructions?\b|(?:最初|初め|はじめ)に(?:受けた|与えられた)指示.{0,12}(?:教え|表示|出力|見せ|そのまま)/iu,
];
// A weakening pattern must not reach across a sentence or a clause: a prohibition in one
// clause ("リンクは付けず、") must not excuse a permission in the next, and the reverse.
const CLAUSE_BREAK = '。.!?！？\\n、,;；';
const bounded = pattern => new RegExp(pattern.source.replace(/(?<!\\)\.\{(\d+),(\d+)\}/gu, `[^${CLAUSE_BREAK}]{$1,$2}`), pattern.flags);
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
  /(?:ignore|disregard)(?:all|any|the|these|those)?(?:rules?|instructions?|guidelines?)/i,
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
  const notAnObjection = /(?:do\s*not|don't)\s+(?:forget|hesitate)|not\s+be\s+shy|never\s+refuse|refuse\s+to|禁止しない|避けない|控えない|ためらわ/giu;
  // "資料にない…" names the gap the instruction wants filled, it is not a prohibition.
  const gapPhrase = /(?:資料|抜粋|参考データ)(?:に|には)?(?:ない|無い|なくても)|記載のない/gu;
  // A clause ends at a sentence mark, a comma or semicolon, or "but"/"ただし"/"しかし".
  const clauseEnd = /[。.!?！？\n、,;；]|\bbut\b|\bhowever\b|ただし|しかし/giu;
  const weakens = v => WEAKENING_INSTRUCTION.some(pattern => {
    const global = bounded(new RegExp(pattern.source, pattern.flags.includes('g') ? pattern.flags : pattern.flags + 'g'));
    return [...v.matchAll(global)].some(m => {
      const from = m.index, matchEnd = m.index + m[0].length;
      // The clause the match sits in: "Never add a link" negates from before the match.
      const breaks = [...v.matchAll(clauseEnd)];
      const startAt = breaks.filter(b => b.index + b[0].length <= from).at(-1);
      const endAt = breaks.find(b => b.index >= matchEnd);
      const clause = v.slice(startAt ? startAt.index + startAt[0].length : 0, endAt ? endAt.index : v.length)
        .replace(gapPhrase, '').replace(notAnObjection, '');
      return !negated.test(clause);
    });
  });
  // Not the whitespace-free variant: "Neverreveal" has no word boundary, so a prohibition would not be seen.
  if (variants(text).slice(0, 2).some(weakens)) throw Error('unsafe_candidate');
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
