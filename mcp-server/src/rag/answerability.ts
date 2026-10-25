import { identifierText } from './identifiers.ts';
// Conservative checks for explicit detail requests. This is not an entailment
// model or a guarantee of correctness, completeness, or document freshness.
const escapePattern = (value: any) => value.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&');
const normalize = (value: any) => identifierText(value).replace(/℃/gu, '°C').toLowerCase();
const money = /(?:\d[\d,.]*|[〇零一二三四五六七八九十百千万億]+)\s*(?:億|万|千)?\s*(?:円|ドル|usd|eur|jpy|ユーロ)|[$€¥]\s*\d/u;
const equation = /[\p{L}\d)】]\s*(?:=|＝|→|⇒)\s*[^\s。]{1,}|\\(?:frac|sum|int)\b/u;
const date = /\d{4}\s*年\s*\d{1,2}\s*月\s*\d{1,2}\s*日|\d{4}[-/]\d{1,2}[-/]\d{1,2}|\d{1,2}\s*時\s*\d{1,2}\s*分|\d{1,2}:\d{2}/u;
const valueWithUnit = /(?:\d[\d,.]*(?:\s*[×x]\s*10\^?[-−]?\d+)?|[〇零一二三四五六七八九十百千万億]+)\s*(?:kj|j|kg|g|km|cm|mm|m|秒|分|時間|%|パーセント|度|°c|k|v|a|ω|hz|円|ドル)(?=\b|[/\s。]|で|と|の|$)/iu;
const rules = [
 { id: 'price', request: /価格|値段|いくら|何円|料金(?=を教えて|は(?:いくら|何円))/u, label: /価格|値段|料金|参加費|定価|販売価格/u, concrete: (s: any) => money.test(s) },
 { id: 'duration', request: /点灯時間/u, label: /点灯(?:時間)?/u, concrete: (s: any) => /\d+(?:\.\d+)?\s*時間/u.test(s) },
 { id: 'revenue', request: /売上|売り上げ/u, label: /売上|売り上げ/u, concrete: (s: any) => money.test(s) },
 { id: 'model', request: /型番|モデル番号/u, label: /型番|モデル番号/u, concrete: (s: any) => /(?:型番|モデル番号)\s*(?:は|が|[:：])?\s*[a-z\d][a-z\d_-]{2,}/iu.test(s) },
 { id: 'formula', request: /数式|方程式|反応式|計算式|構造式/u, label: /数式|方程式|反応式|計算式|構造式|法則|公式|式/u, concrete: (s: any) => equation.test(s) },
 { id: 'derivation', request: /導出|導き方/u, label: /導出|導き|変形|代入|したがって|よって/u, concrete: (s: any) => (s.match(/[=＝→⇒]/gu) ?? []).length >= 2 && equation.test(s) },
 { id: 'aminoSequence', request: /アミノ酸配列/u, label: /アミノ酸配列/u, concrete: (s: any) => /\b[acdefghiklmnpqrstvwy]{6,}\b/iu.test(s) },
 { id: 'baseSequence', request: /塩基配列|dna配列|rna配列/u, label: /塩基配列|dna配列|rna配列/u, concrete: (s: any) => /\b[acgtu]{6,}\b/iu.test(s) },
 { id: 'structure', request: /分子構造|化学構造|構造式/u, label: /分子構造|化学構造|構造式/u, concrete: (s: any) => /結合|原子|炭素|窒素|酸素|水素|二重らせん/u.test(s) && /\d|共有結合|二重結合|単結合|環状|直鎖|二重らせん/u.test(s) },
 { id: 'time', request: /日時|時刻|何月何日/u, label: /日時|時刻|満月|噴火|震源|発生|開催|日付/u, concrete: (s: any) => date.test(s) },
 { id: 'quantity', request: /正確な値|具体的な値|数値|何度|何秒|何キロ|何メートル|何パーセント/u, label: /値|数値|潜熱|温度|速度|速さ|距離|時間|割合|長さ|重さ|質量|内角|角|和|合計/u, concrete: (s: any) => valueWithUnit.test(s) },
];

export function detailRequirements(query: any, comparisonSubjects: any[] = []) {
 const text = normalize(query).slice(0, 4000);
 // Asking what a detail means does not ask for an actual value/sequence/formula.
 const definitionOnly = /^(?:価格|型番|数式|方程式|アミノ酸配列|塩基配列|分子構造|売上)(?:とは|の意味)(?:何|なに|どういう意味|ですか|を説明して|を教えて|[?？。\s])*$/u.test(text);
 const facets = definitionOnly ? [] : rules.filter(r => r.request.test(text) &&
   !(r.id === 'price' && /値下げ|値上げ|割引|何割/u.test(text) && !/いくら|何円|具体的な価格/u.test(text))).map(r => r.id);
 const conditions = facets.length ? [...new Set(text.match(/\d{4}\s*年|[-−]?\d+(?:\.\d+)?\s*°c/gu) ?? [])].map(c => c.replace(/\s/gu, '')) : [];
 const firstDetail = Math.min(...rules.filter(r => facets.includes(r.id)).map(r => text.search(r.request)));
 const prefix = text.includes('について') ? text.split('について')[0] : text.slice(0, firstDetail);
 let subject = /何度|何秒|何キロ|何メートル|何パーセント/u.test(text) ? text.split(/の|を|は/u)[0].trim() :
   conditions.reduce((out,c) => out.replaceAll(c,''),prefix.replace(/\s/gu,''))
     .replace(/メーカー別|地域別|最新|現在|直近/gu,'').replace(/のの/gu,'の').replace(/(?:の|を|は|正確な|具体的な)+$/u,'').trim();
 const requestedDate = /の(\d{4}年\d{1,2}月\d{1,2}日)(?:参加費|料金)/u.exec(text)?.[1] ?? null;
 if (requestedDate) subject = text.slice(0,text.indexOf('の'+requestedDate));
 if (facets.includes('time')) subject = subject.replace(/の出発$/u,'');
 let targets = comparisonSubjects.length ? comparisonSubjects.map(normalize).map(s => s.replace(/の(?:価格|値段|型番|数式|数値).*$/u, '')) :
   subject && !/^(?:これ|それ|あれ|この資料|このページ|その資料|そのページ)$/u.test(subject) ? [subject] : [''];
 const namedLaws = [...text.matchAll(/([\p{Script=Katakana}ー]{2,}の法則)/gu)].map(m => m[1]);
 const quantityLabel = ['潜熱', '温度', '速度', '速さ', '距離', '時間', '割合', '長さ', '重さ', '質量'].find(s => text.includes(s));
 // A symbolic answer is a different kind of evidence, never a numeric value.
 // Opt in only to an explicit, single-subject symbolic substitution request.
 const symbolicRequest = /記号(?:を残した|のまま|を残して)|文字式/u.test(text) && /代入式|代入手順/u.test(text);
 const primary = /^([^。？！\n、,;；]{2,80}?)(?:について[、,]?|の)(?=[^。？！]{0,60}(?:式|記号))/u.exec(text)?.[1];
 const output = /([\p{Script=Han}]{1,12})([a-zα-ω])の(?:式|数式)/u.exec(text);
 const quantityClauses = text.split(/[。？！!?\n]/u).map(s => s.trim()).filter(s => rules.find(r => r.id === 'quantity')!.request.test(s));
 const quantityQuestion = primary && output ? new RegExp('^(?:' + escapePattern(primary) + 'の)?' +
   escapePattern(output[1]) + '(?:' + escapePattern(output[2]) + ')?の(?:数値|正確な値|具体的な値)(?:は|を)?' +
   '(?:確定できる|確定できますか|求められる|求められますか|教えて|教えてください)$', 'u') : null;
 const sameQuantity = quantityClauses.length === 1 && quantityQuestion?.test(quantityClauses[0]);
 const symbolic = sameQuantity && symbolicRequest && primary && output && !comparisonSubjects.length &&
   !/比較|比べ|相違|共通|それぞれ/u.test(text) && !/と|および|かつ|及び|または|[・&/]/u.test(primary) &&
   facets.includes('quantity') && facets.every(id => ['quantity','formula'].includes(id))
   ? { subject: primary, symbol: output[2], quantity: output[1] } : null;
 if (symbolic) { targets = [primary!]; facets.push('symbolic'); }
 // A question that asks for a unit ("何度", "何秒", ...) names its subject before the first の/を/は. When that cut
 // is a clause ("熱帯低気圧が発生するための条件で、中層…"), no sentence of a page can carry it, so the subject-linked
 // check can only refuse. The asked unit is checked on the excerpts by detail-presence.ts instead.
 const clauseLike = (t: string) => /[、,，]|(?:ため|こと|もの|とき|場合|ので|から|まで|で|に|が|を|と)$/u.test(t) || /が.+(?:する|した|され|いる|ある)/u.test(t);
 const unitAsk = /何度|何秒|何キロ|何メートル|何パーセント/u.test(text);
 if (unitAsk && !comparisonSubjects.length && targets.length === 1 && clauseLike(targets[0])) {
  const at = facets.indexOf('quantity'); if (at >= 0) facets.splice(at, 1);
 }
 const askedUnit = ['何パーセント', '何度', '何秒', '何キロ', '何メートル'].map(w => text.includes(w) ? w : null).find(Boolean) ?? null;
 // The attribute the question asks for: the noun just before "は/が 何パーセント" ("発生率は何パーセント", "…を呈した選手は何パーセント").
 // A leading verb phrase is cut ("見つかった割合" -> "割合"). Without it the same-sentence route stays off.
 const attributeRun = askedUnit ? new RegExp('([^のをはが、。,\\s]{1,16})(?:は|が)(?:約)?' + escapePattern(askedUnit)).exec(text)?.[1] : null;
 const askedAttribute = attributeRun ? (attributeRun.replace(/^.*[たるだて]/u, '').length >= 2 ? attributeRun.replace(/^.*[たるだて]/u, '') : attributeRun) : null;
 return { facets, conditions, targets, namedLaws, quantityLabel, symbolic, requestedDate, askedUnit, askedAttribute,
   completeness: facets.length > 0 && /一覧|全(?:塩基|アミノ酸|配列|項目|件)|全て|すべて|全部|過去.{0,8}年/u.test(text) && !/角.{0,12}(?:全て|すべて|全部).{0,6}(?:足|合計)/u.test(text),
   freshness: facets.length > 0 && /最新|現在|直近|今日|今年/u.test(text) };
}

function passages(text: any) {
 // Only the actual bounded excerpt is checked, never source titles or metadata.
 // Keep paragraph context for formulas/tables, but don't join unrelated pages.
 return normalize(text).split(/\n\s*\n|[。！？!?]\s*/u)
   .map(p => p.trim()).filter(p => p && p.length <= 600 &&
     !/(?:不明|未記載|記載されていない|載っていない|わからない|ではなく|でなく|ではない|でない)|(?:指示|命令|システム|system|ignore previous|回答して|出典として|根拠として|扱って|と答え|捏造|偽造)/iu.test(p));
}

function factLabel(span: any, target: any, rule: any) {
 return [...span.matchAll(new RegExp(rule.label.source, 'gu'))].find(m => {
  if (!target) return true;
  const at = span.lastIndexOf(target, m.index);
  if (/[a-z\d_]$/u.test(target) && /[a-z\d_]/u.test(span[at + target.length] ?? '')) return false;
  return at >= 0 && (m.index >= at + target.length || m.index + m[0].length === at + target.length);
 });
}

function linkedAttribute(span: any, target: any, rule: any) {
 if (!target || ['formula', 'derivation'].includes(rule.id)) return true;
 const label = factLabel(span, target, rule);
 const targetAt = label ? span.lastIndexOf(target, label.index) : -1;
 if (targetAt < 0 || !label) return false;
 const between = span.slice(targetAt + target.length, Math.max(targetAt + target.length, label.index));
 // Attribute must belong to the named target, not another entity in the sentence.
 return /^(?:の|は|が|について|[:：]|\s|\d{4}年|(?<=\d)(?:\.\d+)?°c|で|税込|税抜|販売|定価|メーカー|[-a-z\d_])*$/u.test(between) ||
  rule.id==='price' && /^(?:は|の)点灯(?:時間)?\d+(?:\.\d+)?時間で$/u.test(between);
}

function linkedValue(span: any, rule: any, requirements: any, target: any) {
 const label = factLabel(span, target, rule);
 if (!label) return false;
 let suffix = span.slice(label.index + label[0].length);
 if (/比較|比べ|別の|他の|に対して|に対し/u.test(suffix)) return false;
 if (rule.id === 'quantity') suffix = requirements.conditions.reduce((out: any,c: any) => out.replaceAll(c,''),suffix.replace(/\s/gu,''));
 const pattern = ['price','revenue'].includes(rule.id) ? money : rule.id === 'duration' ? /\d+(?:\.\d+)?\s*時間/u : rule.id === 'quantity' ? valueWithUnit : rule.id === 'time' ? date :
   rule.id === 'aminoSequence' ? /\b[acdefghiklmnpqrstvwy]{6,}\b/iu : rule.id === 'baseSequence' ? /\b[acgtu]{6,}\b/iu : null;
 if (!pattern) return rule.concrete(span);
 const value = pattern.exec(suffix);
 if (!value) return false;
 return /^(?:は|が|の和|日時|時刻|[:：]|\s|約|およそ|税込|税抜|で|[-−]|\d{4}年)*$/u.test(suffix.slice(0,value.index));
}

// A question that asks for a unit ("何パーセント") names it, so the value only has to be in that unit. The attribute word
// is open vocabulary (発生率, 標高, ...), so it is taken from the question instead of the closed label list.
// Units that continue into another unit or a different meaning are excluded (m/s, m², km/h, キログラム, 5秒前, 3度目).
const askedUnitValue: Record<string, RegExp> = {
 '何パーセント': /\d[\d,.]*(?:%|パーセント)/gu, '何度': /\d[\d,.]*(?:°|˚|度)(?!も|目|合|ずつ|ほど行|回)/gu, '何秒': /\d[\d,.]*秒(?!前|後|に|ごと|おき|速)/gu,
 '何キロ': /\d[\d,.]*(?:km(?![a-z\/²³])|キロ(?!グラム|バイト|ワット|リットル|カロリー|ヘルツ))/gu,
 '何メートル': /\d[\d,.]*(?:メートル|m(?![a-z\/²³]))/gu,
};
const attributeForms = (attribute: string) => attribute.endsWith('割合') || attribute.endsWith('率') ? /割合|率/gu : new RegExp(escapePattern(attribute), 'gu');
// The attribute is followed by the value (発生率は 59.0 %) or the value by it (約 90 % の選手), with nothing between but particles.
const FILLER = /^(?:は|が|の|も|で|約|およそ|ほぼ|平均|全体|、|,|:|：)*$/u;
// The subject and a value in the asked unit in the same sentence, with no comparison. The subject is compared without
// spaces (an excerpt may write "Hi-Lo テスト") and must not continue into another word ("富士" in "富士通").
function sameSentenceUnitValue(clause: any, target: any, requirements: any) {
 const valueRe = askedUnitValue[requirements.askedUnit];
 const attribute = requirements.askedAttribute;
 if (!valueRe || !attribute || attribute.length < 2 || !target || requirements.symbolic) return false;
 const compact = clause.replace(/\s/gu, ''), name = target.replace(/\s/gu, '');
 if (name.length < 2 || /比較|比べ|別の|他の|に対して|に対し/u.test(clause)) return false;
 let named = false;
 for (let at = compact.indexOf(name); at >= 0 && !named; at = compact.indexOf(name, at + 1))
  named = !/[\p{Script=Han}\p{Script=Katakana}A-Za-z0-9]/u.test(compact[at + name.length] ?? '');
 if (!named) return false;
 const label = requirements.quantityLabel;
 if (label && !(clause.includes(label) || label === '割合' && /率/u.test(clause))) return false;
 if (!requirements.conditions.every((c: any) => { const at = compact.indexOf(c); return at >= 0 && (at === 0 || !/[\d.]/u.test(compact[at - 1])); })) return false;
 const values = [...compact.matchAll(valueRe)].map(m => [m.index!, m.index! + m[0].length] as const);
 const names = [...compact.matchAll(attributeForms(attribute))].map(m => [m.index!, m.index! + m[0].length] as const);
 return names.some(([an, ae]) => values.some(([vs, ve]) => FILLER.test(compact.slice(ae, Math.max(ae, vs))) && vs >= ae || FILLER.test(compact.slice(Math.min(ve, an), an)) && ve <= an));
}

function symbolicSupport(text: any, requirements: any, target: any) {
 const request = requirements.symbolic;
 if (!request || target !== request.subject) return false;
 const escape = escapePattern;
 const definition = new RegExp('^' + escape(request.symbol) + '(?:は|[:：\\s])+', 'u');
 const meaning = new RegExp('^' + escape(request.symbol) + '(?:は|[:：\\s])+' + escape(request.quantity), 'u');
 // Require the same named target to introduce the actual requested left-hand
 // symbol. An unrelated equation elsewhere on the page cannot satisfy this.
 const linked = new RegExp('^' + escape(target) + '(?:では|は|の式は|の数式は|の計算式は|[:：\\s])*' +
   escape(request.symbol) + '\\s*[=＝]\\s*[^\\s。]+', 'u');
 // Keep the definition adjacent to its formula inside one original paragraph.
 // Never join identically named symbols from a different subject/block.
 return normalize(text).split(/\n\s*\n/u).some(block => {
  // Retain unsafe sentences as boundaries; removing one must never join
  // a formula to a definition that was not its original neighbor.
  const spans = block.split(/[。！？!?]\s*/u).map(s => s.trim()).filter(Boolean);
  const safe = (span: any) => { const valid = passages(span); return valid.length === 1 && valid[0] === span; };
  if (spans.some(span => safe(span) && definition.test(span) && !meaning.test(span))) return false;
  return spans.some((span, index) => safe(span) && safe(spans[index + 1] ?? '') && linked.test(span) && meaning.test(spans[index + 1] ?? '') &&
   !/判読不能|未確定|不鮮明|比較|比べ|別の|他の/u.test(span) &&
   requirements.conditions.every((condition: any) => {
    const compact = span.replace(/\s/gu, ''), at = compact.indexOf(condition);
    return at >= 0 && (at === 0 || !/[\d.]/u.test(compact[at - 1]));
   }));
 });
}

function requirementsMet(found: any, requirements: any, index: any) {
 return requirements.facets.every((id: any) => found.has(`${index}:${id}`) ||
   id === 'quantity' && requirements.symbolic && found.has(`${index}:symbolic`));
}

function day(value: any) {
 const m=/^(\d{4})年(\d{1,2})月(\d{1,2})日$/u.exec(value);
 if(!m)return null;
 const d=new Date(Date.UTC(+m[1],+m[2]-1,+m[3]));
 return d.getUTCFullYear()===+m[1]&&d.getUTCMonth()===+m[2]-1&&d.getUTCDate()===+m[3]?d.getTime():null;
}

// Recognize bounded structures in the actual excerpt, never metadata or
// facts stitched across pages. The original text is still sent unchanged.
function structuredSupport(text: any, target: any, id: any, requirements: any) {
 if(requirements.namedLaws.length)return false;
 const normalized=normalize(text);
 if(id==='price' && requirements.requestedDate) {
  if(requirements.conditions.some((c: any)=>c!==requirements.requestedDate.slice(0,5)))return false;
  const q=day(requirements.requestedDate);
  const pattern=new RegExp('^旧版[:：]'+escapePattern(target)+'は(\\d+円)、(\\d{4}年\\d{1,2}月\\d{1,2}日)までの開催に適用[。]新版[:：](\\d+円)、(\\d{4}年\\d{1,2}月\\d{1,2}日)以降の開催に適用[。](?:申込日にかかわらず開催日で判定する[。])?$','u');
  return normalized.split(/\n\s*\n/u).some(block=>{
   const m=pattern.exec(block.trim()); if(!m || q===null)return false;
   const end=day(m[2]),start=day(m[4]);
   return end!==null&&start===end+86400000&&(q<=end||q>=start);
  });
 }
 if(!['time','price'].includes(id)||requirements.conditions.length)return false;
 const parts=target.split('の'); if(parts.length!==2)return false;
 return normalized.split(/\n\s*\n/u).some(block=>{
  const lines=block.trim().split('\n').map(l=>l.trim());
  if(lines[0]!==parts[0]+'の時刻表'||lines.length<3||lines.length>30)return false;
  const cells=lines.slice(1).map(l=>l.split('|').map(s=>s.trim()));
  const header=cells.shift(); if(header!.length!==3||header![0]!=='方向'||header![1]!=='出発'||header![2]!=='料金')return false;
  if(cells.some(row=>row.length!==3))return false;
  const rows=cells.filter(row=>row[0]===parts[1]); if(rows.length!==1)return false;
  return id==='price'?/^\d+円$/u.test(rows[0][2]):/^(?:[01]?\d|2[0-3]):[0-5]\d$/u.test(rows[0][1]);
 });
}

export function referenceSupport(text: any, requirements: any) {
 const spans = passages(text);
 const found = new Set();
 for (const [targetIndex, target] of requirements.targets.entries()) {
  for (const id of requirements.facets) {
   if (id === 'symbolic') {
    if (symbolicSupport(text, requirements, target)) found.add(`${targetIndex}:symbolic`);
    continue;
   }
   const rule = rules.find(r => r.id === id);
   if(structuredSupport(text,target,id,requirements)) {found.add(`${targetIndex}:${id}`);continue;}
   // A price in the same year alone cannot prove applicability on this date.
   if(id==='price' && requirements.requestedDate)continue;
   const clauses = ['price', 'revenue', 'model', 'quantity', 'time'].includes(id) ? spans.flatMap(s => s.split(/[、;]/u)) : spans;
   if (clauses.some(s => {
    if (target && !s.includes(target)) return false;
    if (!linkedAttribute(s, target, rule)) return false;
    if (!requirements.namedLaws.every((law: any) => s.includes(law))) return false;
    const compact = s.replace(/\s/gu, '');
    if (!requirements.conditions.every((c: any) => {
      const at = compact.indexOf(c);
      return at >= 0 && (at === 0 || !/[\d.]/u.test(compact[at - 1]));
    })) return false;
    // A question's temperature is a condition, not the requested answer value.
    return (id !== 'quantity' || !requirements.quantityLabel || s.includes(requirements.quantityLabel)) && linkedValue(s, rule, requirements, target);
   }) || id === 'quantity' && requirements.askedUnit && clauses.some(s => sameSentenceUnitValue(s, target, requirements))) found.add(`${targetIndex}:${id}`);
  }
 }
 return found;
}

export function assessReference(text: any, requirements: any) {
 if (!requirements.facets.length) return { accepted: true, missing: [] };
 const found = referenceSupport(text, requirements);
 const missing = requirements.targets.flatMap((_: any, i: any) => requirements.facets.filter((id: any) => !found.has(`${i}:${id}`)).map((id: any) => `${i}:${id}`));
 // Static excerpts cannot establish that no newer information exists.
 if (requirements.freshness) missing.push('freshness');
 if (requirements.completeness) missing.push('completeness');
 return { accepted: !requirements.freshness && !requirements.completeness && requirements.targets.every((_: any, i: any) => requirementsMet(found, requirements, i)), missing };
}

export function assessReferences(references: any, requirements: any) {
 if (!requirements.facets.length) return { accepted: true, references };
 const contributing = references.map((reference: any) => ({ reference, found: referenceSupport(reference.text, requirements) }));
 const found = new Set(contributing.flatMap((row: any) => [...row.found]));
 const complete = requirements.targets.every((_: any, i: any) => requirementsMet(found, requirements, i));
 // Partial multi-attribute comparisons retain supported facts. A price-only
 // comparison still requires prices for both subjects as before.
 const partial = !complete && requirements.targets.length>=2 && requirements.facets.length===2 &&
  requirements.facets.includes('duration') && requirements.facets.includes('price') &&
  requirements.targets.every((_: any,i: any)=>found.has(`${i}:duration`)) &&
  requirements.targets.some((_: any,i: any)=>found.has(`${i}:price`));
 const accepted = !requirements.freshness && !requirements.completeness && (complete||partial);
 return { accepted, partial:accepted&&partial, references: accepted ? contributing.filter((row: any) => row.found.size).map((row: any) => row.reference) : [] };
}
