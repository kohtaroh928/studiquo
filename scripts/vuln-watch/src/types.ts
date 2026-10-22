// 脆弱性の「指摘」と、その周辺の形。外部(OSV・NVD・JVN)から読んだ JSON は unknown とし、各 query* 関数で必要な項目だけ取り出してこの型にする。

/** 1つの指摘(同じ脆弱性×同じ資産)。osv/nvd/jvn が作る。 */
export interface Finding {
  ids: string[];
  cve: string | null;
  sources: string[];
  /** assetKey(asset) の文字列 */
  asset: string;
  summary: string;
  cvss: number | null;
  cvssSource: string | null;
  fixed: string[] | null;
  status: 'confirmed' | 'needs-review' | string;
  references: string[];
  published?: string | null;
  titleJa?: string | null;
  jvndb?: string;
  matchedBy?: string;
}

/** CISA KEV の1件(掲載されているときだけ付く)。 */
export interface Kev { dueDate: string | null; ransomware: boolean }

/** LLM の判定(検証済み)。 */
export interface Verdict {
  applicability: string;
  confidence: string;
  action: string;
  reason: string;
  evidence: { type: string; ref: string }[];
  unverifiedEvidence?: number;
  [extra: string]: unknown;
}

/** rank() が資産・KEV・EPSS を足し、点数と区分をつけた指摘。triage・cards・report が読む。 */
export interface RankedFinding extends Finding {
  exposure: string;
  sensitive: boolean;
  usage: string | null;
  kev: Kev | null;
  epss: number | null;
  score: number;
  tier: string;
  /** findingId(f)。rank() の直後に cli が付ける。 */
  id: string;
  isNew?: boolean;
  verdict?: Verdict;
  tierBefore?: string;
  needsHuman?: boolean;
}

/** rank() が返す形(id は cli が後で付ける)。 */
export type UnidentifiedFinding = Omit<RankedFinding, 'id'>;

/** 監視対象の1つ(npm パッケージまたは Swift パッケージ)。 */
export interface Asset {
  ecosystem: string;
  name: string;
  version: string | null;
  identity?: string;
  revision?: string | null;
  direct?: boolean;
  exposure?: string;
  sensitive?: boolean;
  usage?: string | null;
  nvd?: NvdHint | null;
}

/** 資産ごとの NVD / JVN の検索ヒント(assets.manual.json の nvd、または直接依存から作る)。 */
export interface NvdHint { keyword: string; products?: string[]; vendors?: string[]; jvn?: { keyword?: string } }

/** package-lock.json の必要な部分。 */
export interface NpmLock { packages?: Record<string, { name?: string; version?: string; link?: boolean; dev?: boolean; devOptional?: boolean }> }

/** Package.resolved(v1 と v2/v3)の必要な部分。 */
export interface SwiftResolved {
  version?: number;
  pins?: SwiftPin[];
  object?: { pins?: SwiftPin[] };
}
export interface SwiftPin {
  location?: string;
  repositoryURL?: string;
  identity?: string;
  package?: string;
  state?: { version?: string; revision?: string };
}

/** assets.manual.json の必要な部分。 */
export interface ManualAssets { assets?: Record<string, { exposure?: string; sensitive?: boolean; usage?: string; nvd?: Asset['nvd'] }> }

/** OSV.dev の脆弱性1件のうち、読む項目だけ。 */
export interface OsvVuln {
  id: string;
  aliases?: string[];
  summary?: string;
  details?: string;
  withdrawn?: string;
  published?: string;
  severity?: { type?: string; score: string }[];
  database_specific?: { severity?: string };
  references?: { url: string }[];
  affected?: { package?: { name?: string; ecosystem?: string }; ranges?: { events?: { fixed?: string }[] }[] }[];
}

/** NVD API 2.0 の CVE 1件のうち、読む項目だけ。 */
export interface NvdCve {
  id: string;
  published?: string;
  descriptions?: { lang: string; value: string }[];
  references?: { url: string }[];
  metrics?: Record<string, { type: string; cvssData: { baseScore: number } }[]>;
  configurations?: { nodes?: { cpeMatch?: NvdCpeMatch[] }[] }[];
}
export interface NvdCpeMatch {
  vulnerable?: boolean;
  criteria: string;
  versionStartIncluding?: string;
  versionStartExcluding?: string;
  versionEndIncluding?: string;
  versionEndExcluding?: string;
}

/** JVN(MyJVN)の1項目を読んだ結果。 */
export interface JvnItem {
  jvndb: string;
  titleJa: string | null;
  description?: string | null;
  cvss: number | null;
  cvssVersion?: string | null;
  link?: string | null;
  published?: string | null;
  cves: string[];
  cpes: { part?: string; product?: string; vendor?: string; version?: string | null }[];
}

/** LLM の判定に渡す1件(buildTriageInput が RankedFinding から作る。外部由来の文章は整形・長さ制限済み)。 */
export interface TriageItem {
  id: string;
  cve: string | null;
  ids: string[];
  asset: string;
  exposure: string;
  sensitive: boolean;
  usage: string | null;
  status: string;
  matchedBy: string | null;
  currentTier: string;
  score: number;
  cvss: number | null;
  kev: boolean;
  epss: number | null;
  fixed: string[] | null;
  summary: string;
  titleJa: string | null;
  references: string[];
  hash?: string;
}

/** 前回の結果の記憶(state.json)。 */
export interface State {
  lastSuccessAt: string | null;
  reported: Record<string, { firstSeenAt: string }>;
  verdicts: Record<string, { hash: string; verdict: object; judgedAt: string }>;
}

/** buildSummary に渡す、その回の実行結果(cli が組み立てる)。 */
export interface RunSummary {
  sourceErrors?: unknown[];
  [extra: string]: unknown;
}
