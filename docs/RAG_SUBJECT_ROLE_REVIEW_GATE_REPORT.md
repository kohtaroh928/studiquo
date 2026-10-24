# 対象role比較：元reviewの採点とprivate保存

2026-10-16。[受入条件](RAG_SUBJECT_ROLE_REVIEW_GATE_ACCEPTANCE.md)に従い、stage0の元review採点helperと、通信なしの保存controlを接続した。全24job実行の完成ではない。

## 変更したもの

- `subject-role-review-artifact.mjs`：packet提出先を確定後、各armの元reviewを既存8観点semantic ledgerで個別に採点する。比較判定と件数を再計算し、元review文字列を保持する。verifyも元reviewから再集計する。
- `subject-role-review-control.mjs`：stage0完了ledgerを別private directoryへ固定する。新manifestは元ledgerの依存closureとpacket/artifact/controlの各source hash、ledger byte hash、run/checkpoint bindingを持つ。旧台帳・保存module/runへ黙って追加しない。
- `rag-subject-role-artifact.test.js`・`rag-subject-role-control.test.js`・合成mock専用helper：元review・collectionの取り違えと障害時停止を検証する。

## 比較判定

candidateがreviewed_matchでmissing/extra上下限0、全armがreviewCompleteかつ全要求representableの場合だけ比較continueにできる。baselineは適合、または確定mismatch_detectedを許容する。baselineのrole欠落は補正せず記録する。baselineのpending/uncertain/unsupportedやcandidate不適合は正規のstop結果として保持する。形式不正reviewは受付拒否し、意味上のstopと混同しない。呼出元のdecision/summaryを入力する欄はない。

stage比較のcontinueは、追加実行の権限ではない。`stage1Authorized=false`・`transportAttached=false`・`releaseAccepted=false`を常に維持する。本人性・実監査の独立性は認証せず、humanReviewVerified=false。今回のケース数を汎用精度や実モデル改善として扱わない。

## 保存と再評価

0700の新directory、0600/単一linkのfile、共通lock/O_EXCLを使う。最初のpacket collectionは一度だけ作成し、全byte hashとmapping hashをpackets_readyへ登録する。別IDで作ったcollectionが単体helperでは妥当でも、最初の登録hashと一致しなければ拒否する。exportは中立packetとそのhashだけを返し、private mappingを含めない。

元review artifactも一度だけ作り、file→directory→journalの同期順で登録する。short write、fsync、close、孤立file、不確実状態は成功を返さずlockを保持する。既存fileを再生成・上書き・自動登録しない。`packets_ready`だけならreview待ちのまま。

再open/各操作時に、全source、元ledger、collection、元review artifactを有界の同一fd読取で再検証し、元reviewから再採点する。改変されたsummaryやcontinue、ケース件数を信用しない。保持中のhandleや読取前後のinode差替え、権限/link/byte/UTF8異常を拒否する。再openを跨ぐ同byte・正規権限のinode置換は保証対象外であり、初回dev/inodeを永続固定していない。hashchainは本人認証ではない。

意味stopでも元artifactを保持し、close後のlockを残す。比較continue/正常review待ちでは、closeでlockを解放して同じ記録を監査のために再openできる。追加予約やstage1を行う入口はない。lock解放後のdirectory同期故障に対するmarker復元はbest effortで、OS障害時の完全保証ではない。

## 検証と残件

対象25回帰（artifact9/control16）：両版適合、baseline確定role不適合、baseline未知/unsupported、candidate不適合、同一plan/同一review内容、提出重複/不足/ID取り違え、元reviewの厳密binding、再集計、別collection、改変summary、source/ledger/checkpoint、孤立/欠損、private mode/link、同時open、byte/UTF8、保持中/読取中差替え、short write/fsync/close同期を確認。全Worker1,615成功（失敗/skip 0）。最終独立コード25・安全23成功。安全レビュー後の追加2回帰はコードレビューで独立確認し、実装は変更していない。未解決High/Mediumなし。[結果JSON](RAG_SUBJECT_ROLE_REVIEW_GATE_RESULTS.json)参照。

追加API/実キー読取0。旧candidate/ledger/journalのsource hash、旧5停止run、最終停止journalを保持する。本番v1・未使用20問も変更しない。rollbackは新helper/controlを呼ばないこと。アプリ/Worker runtime/DB/migrationへ影響しない。

次は、この比較判定・artifactを使う全4stage/24job用の新offline manifest/journalを接続する。今回のstage0用controlはstage1へ流用しない。全先行stageの元review再評価と後半未評価の件数表示を回帰し、その後に新manifestでbounded transport・3箇所secret guard・有限実評価の独立安全gateへ進む。Projectの資料の更新: なし。
