# 指定実教材の自然な質問による検索診断（2026-10-09）

## 実施した範囲

前回の114ページPDFについて、代表ページの画像をPDFKitで確認した上で、自然な質問8件・資料外質問2件をprivate領域へ作成した。質問・教材本文・図・認識結果はリポジトリに追加していない。

アプリの抽出済み本文に対し、製品のcontextualChildren、searchText、queryPlan、importantText、scopeFilterと実際のBM25 SQLをローカルSQLite FTS5で実行した。タイトル・heading contextも検索本文へ含める。canonical質問による関連性判定に加え、比較対象別のcoversSubject＋relevanceEvidenceによるeligible条件も確認した。

実Vectorize、Embedding、RRFの最終順位、Reranker、回答生成は実施していない。以下はキーワード候補とlexical側の診断であり、Hybrid RAGの最終合格率ではない。実Vector検索のscoreが、今回lexicalだけでは除外したページを保持する可能性がある。

## 結果

| 確認 | 現在のコード | 一時環境の区切り方変更 |
|---|---:|---:|
| canonical BM25 Top5に必要ページを含む | 7/8 | 8/8 |
| Query Planの検索候補全体に必要ページを含む | 8/8 | 8/8 |
| 製品のlexical eligible条件で必要ページを保持 | 7/8 | 8/8 |
| 資料外質問のlexical候補を除外 | 2/2 | 2/2 |

比較質問ではcanonical判定だけを見ると対象を落とすケースがあったが、既存の対象別検索・eligible条件で保持できた。これを製品の比較検索障害と誤判定しない。

残った1件は英字略語で指定した対象の動作を尋ねる質問で、必要ページはBM25 Top5に入るがlexical eligible条件では除外される。数式を尋ねた質問について対象ページの候補入りは確認したが、式の転記精度や回答内容は評価していない。

## 原因と確認用変更

searchTokensの非日本語runの正規表現がUnicodeの全letterを含むため、英字から始まるrunが後続の日本語も取り込む。そのrunに日本語が1文字でも含まれると、run全体を日本語としてbigram化する。例えば合成文字列`ABCの概要`は`ab / bc / cの / の概 / 概要`となり、単独の`abc`がなくなる。資料側の単独`ABC`との照合が弱くなる。

private一時環境のコピーで、非日本語runが漢字・ひらがな・カタカナを取り込まないよう区切った。同じ合成文字列が`abc / の概 / 概要`となり、今回の自然な質問のmissを解消した。英数字単独、日本語単独、Cyrillic単独の挙動が変わらないことも確認した。

この変更は製品へ未反映。見つけた同じ質問での確認なので独立holdoutではない。採用前には混在文字の一般回帰、既存の日本語/OCR/negativeセット、旧保存indexとの互換性を検証する。検索本文にも同じnormalizerを使うため、queryだけ修正して旧indexへ適用してはならない。index version更新・明示的な再索引、または旧index互換策を設計する必要がある。関連性しきい値の引下げはしていない。

## 検証と未完了項目

- 現在の関連性・比較・数式評価指標の対象テスト27/27成功。
- private合成診断と対照4件成功。
- 実iPadの再開を試みたが接続できず、実機評価は未実施。
- 外部API呼出し0回。資料の外部送信、deploy、migration、flag変更なし。
- 製品コードは変更せず、報告と集計のみ追加。

次の修正対象は英字と日本語が混在する検索語の区切り方と、保存済み索引の互換性。実紙スキャンの傾き・影、実iPadの114ページ処理・メモリ・中断・出典タップは引き続き未評価。

集計: `RAG_USER_MATERIAL_QUERY_DIAGNOSTICS_RESULTS.json`。

Projectの資料の更新: なし（診断・一時検証のみ。方式採用・公開状態の変更なし）。

## 後続の実装修正

旧形式のFTS保存を維持し、検索時に旧aliasを追加する互換修正を実装・検証した。詳細は[RAG_MIXED_SCRIPT_FIX_REPORT.md](RAG_MIXED_SCRIPT_FIX_REPORT.md)。この報告の一時検証とは採用方式が異なる。
