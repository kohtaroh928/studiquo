# 対象role比較：比較・計算・推薦・要約

2026-10-16。stage2の4合成開発問を両版へ各1回送信し、8件とも形式検証・独立意味レビューを通過した。比較条件の保持、推薦対象への背景名詞の混入防止、共同対象の要約scopeを確認した。計算は要求・対象の抽出だけの評価であり、operand理解・演算・数値結果は未評価である。

今回8送信/8形式完了/技術失敗0、全件reviewed_match・reviewComplete、missing/extra上下限0。累計16送信・比較済み8pair/12、baselineの確定不適合0。両版適合であることを、修正版の優位性や汎用精度に置き換えない。

独立安全確認済みのstage2専用entryでordinal8〜15のstage・順序・bodyhash・固定endpoint/POST・最大8をfetch直前にも制限した。公式[GPT-6 Luna仕様・料金](https://developers.openai.com/api/docs/models/gpt-6-luna)を再取得し、default/medium/store=falseの固定requestを使用。旧run再送・source変更・本番変更なし。

stage2のusageはinput11,392/output1,900（reasoning637はoutput内数）、cache write11,368/cached0。短文default単価input0.10/cached0.01/write0.125/output0.50 USD/百万tokenによる推計0.00237340USD、累計0.00486005USD。実請求・税・地域追加料金・アカウント条件は未確認。累計予約131,072microUSDは実請求上限ではない。stage2応答時間中央値3.771秒、累計3.486秒は保存開始までで、保存同期やRAG全体の時間ではない。

中立packet8件を別担当が原質問・実plan・oracle・provenanceから8観点と全対応候補で監査した。[元監査文書](RAG_SUBJECT_ROLE_COMPARISON_STAGE2_AUDIT.md)を固定し、そのbyte hashと元reviewを照合登録した。元review再採点後の状態はstage3/running、予約/完了/review各16・比較8pair。stage3はまだ予約していない。人間gold・strict blind/本人性認証・総合RAG品質・本番採用は未完了。

次は全3段階の元review/source/runを再検証し、最後の4pairで対象不在・名前中の操作語・無関係な背景を確認する。未知/候補意味不適合/技術失敗は停止し、別path再送なし。既存コード不変で全テスト再実行なし、前工程Worker1,659成功。今回entry構文/mock・実API・保存replay・独立意味/安全監査・文書差分を確認。

[結果JSON](RAG_SUBJECT_ROLE_COMPARISON_STAGE2_RESULTS.json)。Projectの資料の更新: なし。
