# 自然な記号式・数値の複合質問の根拠判定修正

2026-10-13。元の合成熱量質問で、末尾の数値要求が式・記号の説明までinsufficientにする問題を修正した。修正前に同じ自然な質問のretrieval回帰テストが失敗することを確認。評価fixtureを言い換え前へ戻し、元の質問のまま実APIを確認した。

## 設計と変更

answerability.jsに数値根拠とは独立したsymbolic支持を追加。明示記号代入・単一主題・求める量と記号の式・同じ量の数値確認句を狭く認識する。quantity支持を偽って成立させず、対象直結の実式と同段落の直後の原文記号定義が安全な場合に、量の値が不足していても式説明を許可する。missingにはquantityが残る。

価格・別対象・比較・単独数値・最新/完全要求を一般に緩和しない。evidence-selectionの動的facet選択がsymbolic根拠を確保し、取得した式・単位・成立条件の本文を保持。retrievalのowner/scope/再認可、構造化citationsとgrounded/partialの既存意味は変更しない。groundedは資料を使える状態であり、数値が確定した証明ではない。回答policyの未知値補完禁止を維持。

独立Planner設計・レビューで、後半別対象要求の消失、別段落の同名記号定義接合、不正命令除去による偽の隣接を指摘。すべて修正し回帰ケース追加。原文文順を保持して式文と次原文文を個別safe検証、同段落の矛盾定義も拒否。最終High/Medium未解決指摘なし。数式の数学的真偽を証明する仕組みではない。

## 対応範囲と保守的な残件

現在は明示された記号代入・漢字の量名と1文字出力記号・限定した数値質問句・同段落で式直後の定義がある文型を扱う。記号定義が遠い、別段落、複数対象、曖昧な要求などは既存保守判定を維持。一般的な自然言語の完全な解釈とはしない。unsupportedという理由で未知式・価格を一般知識で補完しない。

## 検証

新規回帰22件、対象108件、全Worker1,212件が成功。独立新規22件成功。別実験/同名異義記号、後半の別対象数値、単独数値、価格/比較、命令/未知指数、原文隣接保持、20℃と120℃境界、別式転用、式の条件context維持を確認。差分チェック成功。iOS/設定/migration変更なしのためiOS再実行なし。

実Lunaは元質問1問×explain/source_onlyの2送信。200/completed・返却Luna・各対input/reference/config/citation一致、本人の1ページ出典を確認。2回答とも式/全記号単位/明示代入/未知係数/成立条件を保持。元のfalse-insufficientはこのケースで解消した。promptは今回変更していないため、前回の条件省略が繰り返しで解消したとは断定せず、成立条件保持の安定性と不要背景式は残件として保持。

実Cloudflare検索・実PDF/OCR/iPadではなくproduction handleAI+ローカル合成検索+実OpenAI。固定合成のみmoderationを省略、本番は変更なし。意味機械checksはnot_configured、人手に代わるCodex/独立AI内容確認であり教師評価ではない。

今回2送信: 入力5,516/出力571（思考269含む）/合計6,087tokens。上流4.931秒と3.622秒。既確認単価で概算0.0008371ドル（150円/ドル仮定で約0.13円）、実請求未確認。生の合成回答はprivate0700/0600のみ。repo/Notionは本文・秘密なしmetadataと所見だけ。

## ファイルと次の作業

変更: mcp-server/src/rag/answerability.js、mcp-server/scripts/rag-quality/learning-fixture.mjs。新規: mcp-server/src/rag-symbolic-evidence.test.js、本報告、RAG_SYMBOLIC_EVIDENCE_FIX_RESULTS.json。

次は成立条件の省略と不要な背景式を回答ルール/再評価で確認し、表現・段落配置・未知式・比較へ広げる。今回の式根拠経路を一般に拡張する場合は、否定ケースと独立レビューを先に用意する。前版はprivateバックアップに保持、今回の変更だけを戻せる。公開/本番設定・deploy・migration・push/merge/commitなし。

Projectの資料の更新: なし（既存設計内の根拠判定修正）。
