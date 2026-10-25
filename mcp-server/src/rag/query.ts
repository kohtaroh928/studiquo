// Bounded deterministic rewriting. No extra model call or inferred notebook content.
function conditionReferenceQuestion(query: any) {
  return /^(?:これ|それ|あれ)(?:を(?:使う|使用する|適用する)|の(?:使用|利用|適用|成立))条件を?(?:もう一度|改めて|再度)?(?:教えて|説明して)(?:ください)?[\s。？！?]*$/u.test(query);
}
function referentialQuestion(query: any) {
  return conditionReferenceQuestion(query) || /^(?:これ|それ|あれ|この内容|その内容|この二つ|その二つ|さっきの(?:式|説明|内容)|先ほどの(?:式|説明|内容))(?:は|を|について|の)?(?:しくみ|仕組み|理由|意味|違い|共通点|説明|解説|要約|詳しく|教えて|どういう意味|なぜ|どうして|どうなる|どういうこと)*(?:を|は|が)?(?:説明|解説|教えて|教える|知りたい|詳しく|意味)?(?:して|ください|ほしい|ですか|なの|なのか|か)?[\s。？！?]*$/u.test(query)
    || /^(?:続き|もっと(?:詳しく)?|詳しく|why\??|explain (?:it|that)|tell me more)[\s。？！?]*$/i.test(query);
}
function previousSubject(previous: any) {
  const text = String(previous).trim().slice(0, 600);
  if (!text || referentialQuestion(text)) return "";
  return text.replace(/[\s。？！?]+$/gu, "")
    .replace(/(?:とは|って何|について(?:説明して|教えて|詳しく)|を(?:説明して|教えて)|は何|はなぜ)$/u, "").trim();
}
function previousHasComparedSubjects(previous: any) {
  const text = String(previous).trim().slice(0,600);
  if(!/比較|比べ|違い|相違|共通点/i.test(text))return false;
  const targets=comparisonParts(text).subjects;
  const attributes='用途|使用条件|利用条件|適用条件|成立条件|適用範囲|意味|単位|価格|料金|重さ|重量|サイズ|高さ|幅|奥行|特徴';
  // One subject with multiple attributes is not a choice between subjects.
  if(targets.some((t: any)=>new RegExp(`^(?:${attributes})$`,'u').test(t)))return false;
  const names=targets.map((t: any)=>t.replace(new RegExp(`の(?:${attributes})$`,'u'),''));
  return new Set(names).size>1;
}
export function queryPlan(query: any, previousQuestion = "") {
  const originalQuery = String(query).trim();
  const ambiguous = referentialQuestion(originalQuery);
  const multiplePreviousTargets = conditionReferenceQuestion(originalQuery) && previousHasComparedSubjects(previousQuestion);
  const subject = ambiguous && !multiplePreviousTargets ? previousSubject(previousQuestion) : "";
  const needsClarification = ambiguous && !subject;
  const request = originalQuery.replace(/^(?:これ|それ|あれ|この内容|その内容|この二つ|その二つ|さっきの(?:式|説明|内容)|先ほどの(?:式|説明|内容))(?:は|を|について|の)?/u, "");
  const canonicalQuery = subject ? `${subject}について${request || "説明して"}` : originalQuery;
  const explicitMulti = /比較|比べ|違い|相違|共通|compare|versus|\bvs\b|それぞれ|および|かつ|\band\b/i.test(canonicalQuery);
  // "AとBは、どこで発生しますか": two named subjects asked about together, without a word such as 比較.
  const joint = explicitMulti ? [] : jointSubjects(canonicalQuery);
  const multi = explicitMulti || joint.length === 2;
  const comparison = explicitMulti ? comparisonParts(canonicalQuery) : { subjects: joint, aspect: '' };
  const coverageGroups = comparison.subjects;
  const aspect = comparison.aspect ? `の${comparison.aspect}` : /定義|意味/.test(canonicalQuery) ? "の定義" : /しくみ|仕組み/.test(canonicalQuery) ? "のしくみ" : /働き|役割/.test(canonicalQuery) ? "の働き" : "について";
  const subjectQueries = coverageGroups.map((group: any) => `${group}${group.endsWith(aspect) ? 'について' : aspect}`);
  return { originalQuery, canonicalQuery, ambiguous, needsClarification, multi, coverageGroups,
    queries: coverageGroups.length === 3 ? subjectQueries : [...new Set([canonicalQuery, ...subjectQueries])].slice(0, 3) };

}
// Words that name an aspect of one thing, not a second thing: "メリットとデメリットは" is one subject.
const ASPECT_WORDS = new Set(['メリット', 'デメリット', '長所', '短所', '利点', '欠点', '原因', '結果', '理由', '目的', '方法',
  '手順', '特徴', '意味', '定義', '用途', '価格', '料金', '値段', '発生', '上陸', '種類', '条件', '影響', '対策', '例']);
// Only a question that STARTS with two plain names joined by と and followed by は. Each name must be free of
// particles (の, を, に, で, が, へ): a name with の ("ポーラーロウの特徴と発生条件は") is one subject with two aspects.
function jointSubjects(query: any): string[] {
  const name = '[^とのはがをにでへ、,。？?！!\\n（）()「」『』"]{2,30}';
  const m = new RegExp(`^(${name})と(${name})(?:は|では)[、,]?`, 'u').exec(String(query).trim());
  if (!m) return [];
  const [a, b] = [m[1].trim(), m[2].trim()];
  if (a === b || ASPECT_WORDS.has(a) || ASPECT_WORDS.has(b)) return [];
  // "AというB", "AとされるB", "AといったB": the と quotes or labels A, it does not join a second subject.
  // A name starts with a kanji, katakana, Latin letter or digit, never with a hiragana.
  if (!/^[\p{Script=Han}\p{Script=Katakana}A-Za-z0-9]/u.test(a) || !/^[\p{Script=Han}\p{Script=Katakana}A-Za-z0-9]/u.test(b)) return [];
  return [a, b];
}
function comparisonParts(query: any): any {
  let prefix = query.split(/比較|比べ|違い|相違|共通点|compare/i)[0].trim();
  // Shared requested aspects are not part of the second target's name.
  // Keep them in the bounded subject queries; do not infer shared qualifiers.
  let shared = /の(しくみ|仕組み|働き|役割|特徴|定義|意味|共通点|進み方|代表値|点灯時間と価格)(?:を|の)?$/u.exec(prefix);
  // Repeated attributes qualify each named target rather than a shared suffix.
  if (shared && prefix.slice(0, shared.index).split(/および|かつ|と(?!は)|\s+(?:and|versus|vs\.?)\s+/iu)
    .slice(0, -1).some((p: any) => p.trim().endsWith(`の${shared![1]}`))) shared = null;
  prefix = (shared ? prefix.slice(0, shared.index) : prefix.replace(/(?:を|の)$/u, '')).trim();
  // "AとBは、それぞれ…" / "AとBでは、…どのような違い": the topic marker ends the subjects; what follows is the
  // predicate, not part of the second subject's name. Cut only when the head alone names two or more subjects
  // and nothing is quoted (a quoted name may contain は).
  if (!shared && !/[「『"]/u.test(prefix)) {
    const topic = /(?:では|は)[、,]?/u.exec(prefix);
    const head = topic ? prefix.slice(0, topic.index).trim() : '';
    if (head && head.split(/および|かつ|と(?!は)|\s+(?:and|versus|vs\.?)\s+/iu).length >= 2) prefix = head;
  }
  const quoted = [...prefix.matchAll(/[「『"]([^「」『』"]{2,80})[」』"]/gu)].map(m => m[1]);
  const parts = quoted.length >= 2 ? quoted : prefix.split(/および|かつ|と(?!は)|\s+(?:and|versus|vs\.?)\s+/iu);
  // Only explicit alphabetic model suffixes share a prefix: 灯EとF.
  // Do not infer qualifiers for arbitrary Japanese names.
  if (parts.length === 2 && /^[A-Za-z]$/u.test(parts[1].trim())) {
    const model = /^(.{2,60})([A-Za-z])$/u.exec(parts[0].trim());
    if (model) parts[1] = model[1] + parts[1].trim();
  }
  const subjects = [...new Set(parts.map((p: any) => p.trim().replace(/^(?:この資料の|資料の)/u, "")).filter((p: any) => (p.length >= 2 || /^[\p{Script=Han}]$/u.test(p)) && p.length <= 80))];
  return { subjects: subjects.length >= 2 && subjects.length <= 3 ? subjects : [], aspect: shared?.[1] ?? '' };
}
export function rrf(lists: any, limit = 15) {
  const scores = new Map();
  for (const list of lists) {
    const seen = new Set();
    list.forEach((r: any, i: any) => {
      if (seen.has(r.chunk_id)) return;
      seen.add(r.chunk_id);
      const old = scores.get(r.chunk_id);
      scores.set(r.chunk_id, { ...old, ...r, rrf: (old?.rrf ?? 0) + 1 / (60 + i + 1),
        vectorScore: Math.max(old?.vectorScore ?? -Infinity, r.vectorScore ?? -Infinity),
        vectorRank: Math.min(old?.vectorRank ?? Infinity, r.vectorRank ?? Infinity),
        keywordRank: Math.min(old?.keywordRank ?? Infinity, r.keywordRank ?? Infinity),
      });
    });
  }
  return [...scores.values()]
    .sort((a, b) => b.rrf - a.rrf || a.chunk_id.localeCompare(b.chunk_id))
    .slice(0, limit);
}
export function scopeFilter(scope: any = { type: "library" }) {
  const result: any = basicScopeFilter(scope);
  if (scope.sourceIds !== undefined) {
    if (!Array.isArray(scope.sourceIds) || scope.sourceIds.length > 1000 || !scope.sourceIds.every(validId))
      throw new Error("invalid_scope");
    // A device manifest only narrows authorization; account and document
    // eligibility conditions remain mandatory. Empty never means all sources.
    result.sql += " AND c.source_id IN (SELECT value FROM json_each(?))";
    result.args.push(JSON.stringify([...new Set(scope.sourceIds)]));
  }
  return result;
}
function basicScopeFilter(scope: any) {
  const type = scope.type ?? scope.kind;
  if (type === "library") return { sql: "", args: [], metadata: {} };
  if (type === "folder" && validId(scope.folderId))
    return {
      sql: " AND s.folder_id=?",
      args: [scope.folderId],
      metadata: { folderId: scope.folderId },
    };
  if (
    (type === "notebook" ||
      type === "currentPage" ||
      type === "current_page" ||
      type === "page") &&
    validId(scope.sourceId ?? scope.notebookId)
  ) {
    const id = scope.sourceId ?? scope.notebookId;
    if (type === "notebook")
      return {
        sql: " AND c.source_id=?",
        args: [id],
        metadata: { sourceId: id },
      };
    if (Number.isInteger(scope.pageNumber) && scope.pageNumber > 0)
      return {
        sql: " AND c.source_id=? AND c.page_number=?",
        args: [id, scope.pageNumber],
        metadata: { sourceId: id, pageNumber: scope.pageNumber },
      };
  }
  throw new Error("invalid_scope");
}
export const validId = (id: any) =>
  typeof id === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(id);
