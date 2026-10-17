# 対象role比較：実APIの次の3pair

2026-10-16。[stage0](RAG_SUBJECT_ROLE_COMPARISON_API_RUN_REPORT.md)の元reviewと保存内容を再確認し、同じ正常runでstage1の3問を両版へ各1回送信した。**6送信すべて形式検証・独立意味監査を通過したが、各問の両版planは同一で、改善効果はまだ確認できない。**

前文の対象と後文の説明、適用状況付きの条件要求、別対象に対する別属性の独立要求を確認した。複数unitをまたぐ対象・属性・条件の対応を保持できた。同一対象の原文中の別の出現を参照した場合も、oracleの代表位置と違うだけで誤り扱いせず、意味と参照の妥当性を独立確認した。

| 項目 | 今回stage1 | 累計stage0+1 |
| --- | --- | --- |
| 実送信 / 形式完了 / 技術失敗 | 6 / 6 / 0 | 8 / 8 / 0 |
| 独立意味監査 | 6件ともreviewed_match | 8件ともreviewed_match |
| 比較済みpair | 3 | 4 / 12 |
| input / output tokens | 8,375 / 1,429 | 11,134 / 2,191 |
| reasoning（output内数）| 459 | 807 |
| cache write / cached | 8,357 / 0 | 11,110 / 0 |
| usage由来の費用推計 | 0.001760925 USD | 0.002486650 USD |
| 予約microUSD | 49,152 | 65,536 |
| 応答時間中央値 | 2.964秒 | 3.079秒 |

実請求は未確認。予約は実請求上限ではない。時間は保存開始時までで、保存同期込みの正確な全時間やRAG全体の応答時間ではない。少数の送信から速度優位性を主張しない。

OpenAI Docsで[公式Luna料金](https://developers.openai.com/api/docs/models/gpt-6-luna)を再取得し、default・短文のinput 0.10 / cached 0.01 / cache write 0.125 / output 0.50 USD/百万tokenで推計した。cache writeをinputから区分しreasoningを二重加算しない。税・地域追加料金・アカウント条件・実請求は未確認。

## 安全確認と元review

別のprivate stage1専用entryを使い、既存runのstage0承認済みjournal byte hash・監査文書・artifact・manifest/source・元reviewのreplay・旧5停止lockを確認した。fetchの直前でもordinal2〜7の順序・stage1・固定endpoint/POST・本文hash・最大6回を強制する。stage0/stage2本文・順序違い・7回目等をmockで拒否し、独立安全確認後のみ実行。旧stage0 entryの再実行、新run作成、再試行はない。

中立packet6件を独立担当が個別に8観点・全task×requirement候補で監査した。[固定した根拠文書](RAG_SUBJECT_ROLE_COMPARISON_STAGE1_AUDIT.md)のbyte hashを元reviewと照合し、private artifactへ登録。全先行stageの元review・保存plan・原文参照を再採点するjournalで比較continueとなった。最終状態はstage2/running、比較済み4pair、生成・全体監査・本番採用は未完了。stage2の予約・送信は行っていない。厳密blindやreviewer本人性は認証されていない。

## 残件

合成開発4問での要求抽出確認であり、汎用精度・検索/回答/OCR/100ページPDF/iPadの品質ではない。人間goldはpending。次はsource・run・2段階の元reviewを再確認し、stage2の4pair（8送信）を専用上限付きentryで有限比較する。条件付き比較、計算、推薦の背景除外、複数対象の要約が続く。未知・候補意味不適合・技術失敗は停止し、別pathへ自動再送しない。

既存コードとテストは変更していないため全Workerテストは再実行していない。前工程1,659成功を維持。今回はentry構文/送信制限mock、実API、source/保存replay、独立意味/安全監査、文書・差分を検証した。本番v1、未使用20問、旧停止runを保持し、deploy/migration/push/mergeなし。

[結果JSON](RAG_SUBJECT_ROLE_COMPARISON_STAGE1_RESULTS.json)。Projectの資料の更新: なし。
