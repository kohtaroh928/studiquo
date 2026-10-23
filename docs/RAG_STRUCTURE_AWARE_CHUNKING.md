# Docling構造を使う本文分割

2026-10-16。ユーザー依頼「分割の部分を修正」に対する実装単位。codex/rag-wip、既存未コミット変更は保持する。開発手順full、独立Plannerで受け入れ条件を確認。

## 対象と設計

Doclingが出力する構造JSONを受け、本文だけへ意味境界判定と再帰的長さ調整を適用する。table/picture/formulaなどを本文として再分割せず、ページ・要素・由来を保持する。通常のWorker chunkPage/indexSource・DB・索引形式・本番設定は今回変更しない。

現Workerはpages.textを再分割するため、従来のpages-outputだけを渡しても新分割は保持されない。新しいchunks-outputをローカルで利用可能にし、将来の構造化index入力接続は別段階とする。アプリ自動経路へ適用済みと主張しない。

- 順序は物理ページ→明示構造→本文element→文単位の意味境界→必要部分の再帰分割。ページと要素境界は越えない。短い本文を無理に大きく結合しない。
- 本文kindはallowlistで限定する。表・図・数式・caption・unknown要素はprotected扱いとし、内容・表セル・provenanceを保持する。巨大protected要素は上限超過を明示し、本文の長さ上限を満たしたことにしない。
- 原文elementId/self_ref、page、親子/caption参照、見出し情報を保持する。欠落した関係はunknownとし、近い要素を図の説明/式の条件として断定しない。図/式の認識品質は初期Docling profileの制約を引き継ぐ。
- 再帰分割は空行→改行→文→空白→Unicode文字の境界を優先し、既定400推定token/65推定token重複を目標にする。tokenは埋め込みモデルの厳密tokenではない。原文offsetとcoverageを保持し、欠落/置換/Unicode破損を防ぐ。
- 意味境界は隣接文の明示ベクトルによるcosine distanceで判定。ベクトルは入力text hash・原文unit hash・順序・モデル名へbindし、件数/次元/非有限値/ゼロnorm/不一致は拒否する。ベクトルなしはrecursive fallbackでsemanticApplied=falseと理由を出し、意味分割済みと偽らない。準備済みベクトルを明示ファイルから使う実経路を用意するが、新API呼出やモデルdownloadを暗黙に追加しない。

## 実装・検証計画

1. tools/docling/extract_pdf.pyで元Doclingの明示参照と階層を保持し、従来pages.textは変更しない。
2. 新しいpure分割モジュールと、CLI chunks-output/明示vectors入力を追加。既存のoffline・固定error・private新規出力を維持する。
3. 本文lossless/offset再照合、同じ文の反復、見出し境界、100ページ、巨大protected要素、空白/長文、日本語、cosine境界、不正vector、失効/未割当由来の取り扱い、決定性を合成テスト。
4. 実合成Docling PDF→chunksのsmokeで表が本文へ混ざらず、ページと元要素を参照できることを確認。
5. 独立契約・コード安全レビューと記録/Notion更新。回答精度とsemanticモデル品質は別評価とする。

## 障害・互換性・停止方法

入力/ベクトル/出力はbounded、原文やベクトルを通常ログへ保存しない。無効入力を切断/推測で修復せず固定codeで拒否。出力は明示的新規privateファイル、既存ファイルを上書きしない。元Docling出力とのrelationが欠けても捏造しない。CLIの新しいchunksオプションを使わなければ既存抽出経路を維持する。rollbackは新オプションの利用停止で、本番DB/索引移行は不要。

## 参考

[Docling chunking](https://docling-project.github.io/docling/concepts/chunking/)の構造・token調整・表見出し保持と、[LlamaIndex semantic splitter](https://developers.llamaindex.ai/python/framework-api-reference/node_parsers/semantic_splitter/)の埋め込み距離による文境界判定を確認した。今回の方式はStudiquoの明示ページ参照/本文限定境界に合わせる実装で、それらのライブラリを導入したという意味ではない。

## 実装結果

`tools/docling/structured_chunking.py`を追加し、extract_pdf.pyの`--chunks-output`へ接続した。本文allowlistはtext/paragraphの2種。表/図/式に加え、見出し/リスト/脚注/caption/未知kindをprotectedElementsへ保持する。巨大要素も改変せずoversizedを付け、保護要素が400推定token以内だと偽らない。本文chunkは原要素ID・ページ・Unicode codepoint範囲・provenance・明示contextrefsと未解決状態を保持する。

見出し関係は明示parent ancestryだけを使い、親がbody/group等で見出しに到達しなければunknown。近接によるcaption/数式条件の推測は行わない。要素self_refがなければ抽出順のsynthetic_unknown IDで、永続的な原資料IDとは区別する。

意味分割は同一本文要素内・120推定token以上・複数文に限定。cosine distance閾値0.35は初期設定で品質調整済みではない。別段落の意味統合や小段落の再梱包は未実装。`semantic_manifest.py`で本文/hash/offsetの一致するunit manifestをprivate出力し、別途準備したlocal encoderのベクトルを明示ファイルで渡せる。encoderの導入/モデルdownloadは今回追加していない。モデル名は識別情報で真正性や意味品質の証明ではない。

再帰分割は400推定token/重複最大65推定token、Unicode文字の原文範囲を保持する。空行→改行→文→空白→文字を優先し、意味境界/原要素/ページは越境しない。推定はASCII文字1/非ASCII文字4のweightを4で割り切り上げたもの。既存BGE tokenizerの厳密計数ではない。

`pageStates`にneedsReview/needsOCRを必須boolで保持し、本文chunk/保護要素/全体へreviewRequiredを伝搬する。未割当要素も別保持し全体を要確認にする。vectorなしはsemanticApplied=false/no_vectors、正しいvectorだが対象unitなしはnot_needed。不正/欠落/別本文/JSON nullの明示vectorは停止し、正常fallbackにしない。

## 検証

- Python最終34件成功（失敗0）。本文範囲とlossless coverage・重複量・日本語・長文・100ページmock境界・保護要素・cosine境界・原文hash/モデル/次元・global上限・ID重複・manifest roundtrip・不正vector出力なし・ページreview伝搬を検証した。
- 独立Planner34件/コード安全34件成功。レビューでページ確認状態の消失と明示JSON nullのsilent fallbackのMediumを発見し修正、関連回帰を追加。共通入力上限とID重複もmanifest/分割の両経路で拒否。最終未解決High/Mediumなし。
- 実Doclingの合成2ページで4本文chunk/4保護要素（2表）を確認。実装担当の最終smoke03と親の別出力で、ページ・原文範囲・表保護・private0600・確認状態を検証した。実PDFsmokeはベクトルなしの再帰経路。意味分割は合成ベクトルによる分岐/整合性テストであり、実embeddingモデルの意味品質・検索改善を検証したものではない。
- Workerソース・凍結fixture/validator/意味reviewの記録hashと完了実runの固定manifestが不変。Python/localのみの変更のためWorker全テストは再実行していない。直前1,707成功は前工程の結果。API/鍵読取/モデル追加取得/本番操作0。

## 残件

アプリ/Worker索引への新chunks入力接続、短いparagraphの統合、実embeddingでの意味分割品質と検索比較、日本語OCR/数式/図の内容理解、実100ページの推論性能は未完了。既存pages.textへ戻すとWorkerが従来方式で再分割するので、新方式が本番RAGへ反映済みとはしない。

自動実行PAUSED維持、deploy/migration/push/mergeなし。Projectの資料の更新が必要: [設計] HYBRID_RAG.md。複製の置き場は変更していない。
