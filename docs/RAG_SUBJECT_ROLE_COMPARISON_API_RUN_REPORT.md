# 対象role比較：実APIの最初の1pair

2026-10-16。固定した合成開発12問のうち、最初の1問を従来版・修正版へ各1回送信した。両方とも通信・形式検証・独立意味レビューを通過し、元reviewをprivate artifactへ登録した。**両版のplanは同一で、この1問で改善効果が確認できたとは言えない。**

## 結果

| 項目 | 結果 |
| --- | --- |
| 実送信 / 形式完了 / 技術失敗 | 2 / 2 / 0 |
| 独立意味判定 | 両版reviewed_match、reviewComplete |
| 比較済みpair | 1 / 12 |
| 対象・属性・条件・要求分割 | 各2要求を適切に保持 |
| 時間 | 従来版5.412秒、修正版3.034秒 |
| input / output | 2,759 / 762 tokens |
| reasoning / cached / cache write | 348（output内数）/ 0 / 2,753 |
| usageからの費用推計 | 0.000725725 USD（実請求未確認）|
| 予約 | 16,384 microUSD（実請求上限ではない）|
| 後続stageの予約・送信 | 0 |

一つのunitから2要求へ分割し、それぞれの明示対象をsubjectsへ保持できていることを確認した。背景名詞や複数unitに分散した条件は今回まだ評価していない。時間は保存開始時までであり、保存同期を含む正確な全所要時間やRAG全体の応答時間ではない。2回の違いから速度優位性も主張しない。

## 事前確認と実行制約

OpenAI Docsで[GPT-6 Lunaの公式仕様・料金](https://developers.openai.com/api/docs/models/gpt-6-luna)を実取得した。100万tokenあたりinput 0.10 / cached 0.01 / cache write 0.125 / output 0.50 USD。固定requestはgpt-6-luna、medium、service_tier=default、store=false、toolsなし。短い入力であり272K超の長文追加料金は想定しない。地域追加料金・税・アカウント条件・実請求は未確認で、推計はそれらを含まない。cache writeをinputから区分し、reasoningをoutputへ二重加算していない。

最終source・manifest、旧5停止lock、旧v4停止journal hash、新canonical run未使用を確認。初回preflightはprivate entryがservice_tier未定義を誤って要求したため停止した。既存の固定bodyがdefaultであることを確認し、entryの検査だけ修正した。キー読取・送信前の停止で、既存request/sourceの変更や旧run再送はない。

独立安全レビューで、directory存在確認後に別処理が進行した場合のstage0上限にMedium指摘を受けた。private entryのfetch wrapperで、native fetch前に先頭2jobのstage・順序・本文hash・endpoint・POST・最大2回を照合するよう補強した。stage1本文・3回目・別endpointを送信前に拒否するmockを実施し、独立確認でHigh/Medium残件なし。その後のみ既存キーを非表示で読み、最初の1pairを実行した。再試行なし。

runは `/private/tmp/studiquo-rag-subject-role-live-20261016-01`、manifest hashは `3be1b351bb6f7c9787415ea568e3710b0bc2dde17396cdec6285b8a81a100744`。private entryはstage0専用で、**同pathのstage0を再実行しない**。

## 独立監査と残件

中立packetだけを別担当へ渡し、実plan・原質問・oracleを8観点で個別評価した。全task×requirementの交差対応も確認。[固定した元監査](RAG_SUBJECT_ROLE_COMPARISON_STAGE0_AUDIT.md)のbyte hashを各reviewと照合してから登録した。元review・collection・mappingはprivate保存し、journalが再採点した比較continueを保持する。strict blindや本人性の認証ではない。

既存コードは変更していないため全Workerテストは再実行していない。直前の対象21・全Worker1,659成功は前工程の結果であり、今回の実API意味評価とは別である。今回はprivate entryの構文・送信制限mock・source/hash・journal replay・独立意味/安全監査・文書差分を検証した。

人間gold確認、本番採用、検索/回答/OCR/100ページPDF/iPadの総合品質は未完了。未使用20問、本番prompt v1、feature flag、旧停止runを保持し、deploy/migration/push/mergeなし。次は登録済みreviewとsource/runを再確認し、別の有限entryでstage1の3pairだけを比較する。意味不適合・未知・技術失敗では停止し、後続stageは元reviewの独立確認後だけ進める。

[結果JSON](RAG_SUBJECT_ROLE_COMPARISON_API_RUN_RESULTS.json)。Projectの資料の更新: なし。
