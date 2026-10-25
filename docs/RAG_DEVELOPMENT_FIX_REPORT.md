# 調整用評価後の修正と診断

2026-10-14。作業先 `.worktrees/rag-wip`。[結果metadata](RAG_DEVELOPMENT_FIX_RESULTS.json)。本番反映・commit・push・mergeなし。

## 修正した部分

- queryの指示語判定に、文全体が「それ/これ/あれ＋使用/適用条件＋説明依頼」に一致する限定的な文型を追加。対象/履歴がない場合は検索前にclarificationへ進む。既知の単一対象は維持し、比較した2対象のどちらかを勝手に選ばない。
- 単一対象の複数属性を複数対象と誤認するレビュー指摘を修正。「用途と使用条件」「成立条件と適用範囲」の履歴を維持する回帰を追加。
- 回答policyに発行日と適用開始日、資料で明示された従来規則、期間/優先不明の矛盾を区別する基本ルールを追加。開始前だから必ず旧規則と推定しない。
- 既知記号の意味/単位の明示、日本語の一般文、資料からの答えを先に示して必要補足を後に置くルールを強化。
- 再確認runnerへ最大3問のdevelopment限定selectionを追加。holdout/未知/重複/過剰IDを拒否し、selectionもmanifestへ固定。旧設定のjournalへ別promptで継続しない。

無効化/障害fallbackの通常chat、同意/認証/テナントfilter/課金/削除/DB/flags/iOSは変更しない。current-pageの既存context overrideも変更しない。指示語の対応文型は限定的で、一般的な代名詞解決が完成したとは言わない。

## 原因切り分けと評価側の修正

元versions-03を本番handleAIのmock経路で確認し、従来の2日前と新ルールの4月1日開始が両方contextへ渡ることを確認。検索で旧規則が消えたのではなく、LLM回答層で適用関係を拒否している。

最初のpolicy修正(r1)で指示語の確認と全記号単位は改善したが、締切は両style未改善。文脈対応を強めたr2はsource_onlyのみ2日前、explainは未改善。r3は両style未改善。資料にない「別の便」という区別を追加した回答もあった。未改善結果は保持し、良い結果で上書きしない。

元の「従来便」は同じ対象の旧規則として自然に読める一方、対象の同一性と旧規則の期間が明記されていない。以前の評価ではこれを確定した誤回答と扱ったが、後続診断で評価資料の解釈の余地が判明した。現在は**作成者の正解と不一致・意味前提の人間判定待ち**として扱い、元fixture/gold/結果を保持する。これ以上断定を強める調整を打ち切り、成果の出なかったr2/r3の対応強化文を除去。r1の基本ルールと他の修正を保持した。最終policyはprivate r1 snapshotとbyte一致を確認。

別suite/hashの診断では、同じ合成輸送便の改訂前の規則であることと、3月31日まで旧2日前ルールを適用することだけを追加。同じ質問・正解項目を保持し、元50問を変更しない。両styleが2日前と回答した。ただし**元問題の成功へ算入しない**。r1の元問題と診断は同じ最終policy/設定で比較可能だが、モデルalias・時刻・確率的出力もあり、曖昧さが唯一の原因と断定しない。

## 検証

指示語回帰の新3テストは修正前3失敗、修正後成功。embedding/Vector/FTS検索0、既知履歴維持、比較履歴確認、名前付き質問維持を確認。本番mock経路で両styleの新policy到達・clarification・旧新contextと出典page1を検証。再確認selectionと別診断の不変性も検証。

対象47件、全Worker1,244件成功、失敗/skip0、差分確認成功。独立計画・code review・安全review実施。履歴のMedium指摘を修正し、再レビューHigh/Mediumなし。独立対象47件成功、selector独立11件成功。iOS未変更・今回未実行。

実APIはr1/r2/r3各6、別診断2、対照6の計26送信。10/14は14送信。元の60回答と別集計し、未使用40回答は送信していない。固定合成資料と最小base＋grounded policyによる回答層の確認であり、全production prompt/実Cloudflare/PDF/OCR/iPadではない。

独立内容確認では、指示語と記号説明の改善を確認。最終基本policyの対照は、明確な日付の1,500円、不明優先の予約案内の未確定、複数ページの1,800円/事前受付/現金/カード不可を維持し、日本語以外の単語も今回出なかった。軽微な網羅候補として、料金source_onlyでは開催日が判定基準である理由を明示していない。金額は正しい。人間の採点は未実施。

## 費用・保持・残件

修正評価26送信の入力79,539/出力4,012（思考2,494含む）/合計83,551tokens。全入力をStandard非cachedとして計算した概算0.0099599米ドル。実請求/税/Cloudflare/OCRは含まない。[公式料金](https://developers.openai.com/api/docs/models/gpt-6-luna)を10/14再確認。保守予約0.13312米ドル、元60回答分を含む予約合計0.44032米ドル。予約と実費概算を混同しない。

生の合成回答はprivate0700/0600のjournalだけ。repo/Notionはmetadataと所見のみ、キー・実ノート・個人情報は入れない。旧60回答journalの変更なしと、新promptでの再開拒否を確認。10/13のr3送信はCodex利用上限で自動承認が完了せず、未実行だった。10/14に通常承認経路で再申請して実行し、承認を迂回していない。

残件: 元締切問題の正解前提の人間確認、文脈省略を許容する採点基準の整理、未知型番/複数改訂/旧期間不明の別対照、最終policyでの広い再評価、full production API経路、未使用20問、実検索/PDF/OCR/iPad。数回の同一問題の調整から汎用精度・反復安定性・本番可能性は主張しない。

変更ファイル: `src/rag/query.js`、`src/rag/answer-policy.js`、`scripts/rag-quality/evaluation-50-live.mjs`、`src/rag-answer-style.test.js`、`src/rag-evaluation-50-live.test.js`（いずれもmcp-server内）。新規: `src/rag-condition-reference.test.js`、`scripts/rag-quality/evaluation-50-explicit-rule.mjs`、`src/rag-explicit-rule-diagnostic.test.js`、本報告とmetadata。

切り戻しは今回のquery/policy差分とselectionだけを対象とし、private結果/予約を保持する。既存未コミット変更を巻き戻さない。migration・secret・binding追加なし。

Projectの資料の更新: なし。
