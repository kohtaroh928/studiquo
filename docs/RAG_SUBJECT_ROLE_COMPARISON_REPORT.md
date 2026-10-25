# 対象role比較：全4段階・24jobのoffline統合

2026-10-16。[paired設計](RAG_SUBJECT_ROLE_PAIRED_DESIGN.md)と[受入条件](RAG_SUBJECT_ROLE_REVIEW_GATE_ACCEPTANCE.md)に沿い、stage0の検証を全12pair/24jobへ広げた。通信・鍵・実モデル評価は今回も接続していない。

## 実装

新`subject-role-comparison.mjs`は固定manifest、保存完了結果の再検証、各stageの中立packetと元review artifactを扱う。共通8観点semantic ledgerを使い、旧stage0 artifactとのparityで判定規則の差を監視する。旧sourceを変更して黙って置き換えることはしない。

新`subject-role-comparison-journal.mjs`は2/6/8/8jobの4段階で、予約→形式完了→checkpoint→packets_ready→元reviewの再採点を記録する。質問index/variant/ordinal/pairIndex/requestHashを固定し、偶数問baseline→candidate・奇数問逆順を保持する。stage予約16384/49152/65536/65536、全予約196608microUSD。**予約は実費・実請求上限・実送信証明ではない。今回のAPI送信は0。**

source closureは新2module・元request/response・質問/分割/schema・oracle・8観点採点規約・旧stage0判定referenceを含む。別suiteでtransportAttached=false・dispatchAuthorized=false・releaseAccepted=false。旧stage0 module・offline run・旧5停止runは流用しない。

## 判定と状態

- checkpointとpackets_readyだけでは次の予約を許可しない。元reviewから再計算した比較continueだけで次stageへ進む。
- candidate適合、全armのreviewComplete/representableが必要。baselineは適合または確定不適合を許す。未知/unsupported/candidate不適合は意味stop、HTTP等の技術失敗は技術stop。
- 初期、checkpoint監査待ち、packet準備済み、review続行済み、最終監査済みを正常再開の区切りとする。予約未完了・途中pair・checkpoint前・失敗・保存不明ではlockを保持する。
- baseline/candidate完了数、技術完了pair、partial pair、予約済み/未予約pair、比較可能pairを別に数える。途中停止の後半を評価済み扱いしない。
- 24jobの形式完了generationCompleteと、全24armのreviewCompleteを満たすallReviewsCompleteを分ける。最終stageのreview待ちでは生成完了でも監査未完了。
- baselineMismatchCount/candidateAllMatchedは全体監査が完了するまでnull。prefixの観測結果はobservedBaselineMismatchCount/observedCandidateAllMatchedへ別表示する。比較continueは採用・releaseや実API送信権限ではない。

## 保存・安全性

0700/0600、単一link、canonical directory、共通lock/O_EXCL、file→directory→journal同期を維持する。最大4個ずつのcollection/artifactを一度だけ作り、初回collectionの全byte hashを固定する。元reviewは文字列のままartifactへ保持し、毎回元データから再採点する。

再open・各操作・予約直前に全先行stageのcollection/artifact、binding、byte hash、元review、sourceを再検証する。summary/continue文字列だけを信用しない。孤立・欠損・改変・mode/link・保持中や読取中のinode差替えは予約前に拒否する。保存のshort write/fsync/close不確実時は成功を返さずlockを保持する。

同じOS userの全記録改変を防ぐ本人認証基盤ではない。再openを跨ぐ同byte・正規権限のinode置換は保証しない。元raw responseの保持はなく、responseHashは構文確認とローカル記録のbindingに限られ、上流実行の証明ではない。レビュアー本人性・独立性・厳密な盲検も保証しない。marker復元はOS障害時best effort。

## 検証

対象23回帰（pure7/journal16）：全24job・4stageの完走mock、最終レビュー前/後、baseline確定不適合/candidate停止、未知/unsupported、両arm技術失敗、partial、checkpoint/packets_ready予約拒否、全先行stage再検証、改変と再hash、arm不足/重複/混入、孤立/二重受付、source変更、private mode/link、同時open、byte/UTF8、旧suite拒否、short write/fsync全保存phase、読取中差替え、snapshotを確認。

旧stage0とのparityはpass、baseline確定不適合、unknown/representation uncertain/unsupported/incomplete、candidate不適合/unknown/unsupported、不正reviewを含む。初回はfs named importを障害注入mockが捕捉しなかった1試験を、他wrapper同様のdefault fs importへ揃えて再検証した。実際のsourceをテストで書き換えてはいない。

全Worker1,638成功（失敗/skip 0）、独立コード23・安全23成功。未解決High/Mediumなし。[結果JSON](RAG_SUBJECT_ROLE_COMPARISON_RESULTS.json)参照。すべて合成mockであり、モデル精度やRAG回答品質の改善を示さない。

## 次の作業

新transport用manifestに通信層sourceを固定し、同じ24job/段階監査へbounded transport・3箇所secret guard・deadlineを接続する。timeoutやstage時間は今回入力elapsed値の上限検証までであり、実通信全体の時間保証は未接続。通信mockと独立安全確認の後に、料金・新canonical directory等のpreflightをして有限実評価へ進む。今回のoffline runをpaid runへ転用しない。

本番v1・未使用20問・旧sourceと停止runを保持。追加API/実キー読取0。rollbackは新2moduleを呼ばないこと。アプリ/Worker runtime/DB/migrationへの影響なし。Projectの資料の更新: なし。
