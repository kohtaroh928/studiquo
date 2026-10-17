# v4評価journalと原review artifact gate

2026-10-15。High変更のうち通信なし基盤だけを実装。[有限run設計](RAG_UNIT_PLANNER_LIVE_DESIGN.md)に従い、旧v3ソース・run・journalは保持する。外部API・key loader・CLI・自動実行の入口は持たない。本番やDBへの変更なし。

## 実装した範囲

- `unit-task-planner-journal.mjs`：別offline manifest（contract4/transportAttached:false）を固定。request32KiB・固定8job・予約8192microUSD/件・1+3+4を記録する。予約のdurable保存、hashchain、private owner/mode、排他lock、異常時停止・lock保持、正常checkpoint以外の再開禁止を維持する。
- 保存planを固定質問から再検証し、serverのunit/provenanceを再生成する。model/usageも合成envelopeで再検証する。保存provenanceやhash文字列だけを信用しない。
- `unit-task-planner-artifact.mjs`：通信/IOなしの独立review集計。対象stageのcaseを過不足・重複なく確認し、各caseのquestion/plan/oracle/review hashとsemanticStatusを残す。continueには全case reviewed_match・reviewComplete・missing/extra上下限0を要求する。未確認や表現不能を母数から除外しない。
- `unit-task-planner-review.mjs`：journalと同じ排他lockを取得する別入口。元review JSONとcase summaryを固定stage名のprivate artifactへO_EXCLで一度保存し、file→directory→journalの順に同期する。孤立artifactの上書き・再登録を行わない。
- 全先行stageのartifactはopen/guard/予約/書込/close時に再検証する。固定名・最大2MiB/各stage・最大3個、同一fdを使ったstat/read/hash・読取中byte上限・inode/mtime/ctime/link/mode/owner確認を行う。rawreviewを再評価し、保存summaryだけでcontinueしない。JSONとhashを正しく書き換えた形式上の偽summaryも再評価で拒否する。
- レビューのroleや成果物hashは本人認証/独立性/意味の正しさを証明しない。実成果物とレビューの独立性は信頼する呼出元がworkflowで確認する。人間gold確認pending/release falseは維持する。

## 回帰と未実施

専用21テストで正常1+3+4・最終生成と最終reviewの分離、予約/保存/lock故障、元plan/provenance・source改変、孤立/欠損/改変/上限/mode/symlink/hardlink artifact、読取中差替、stage0削除後のstage2予約拒否、pending/unsupportedのcontinue拒否等を確認した。全Worker1,497件成功、失敗/skip 0。独立code/安全は各21件成功、High/Medium残件なし。最終hashと結果は[RAG_UNIT_PLANNER_JOURNAL_RESULTS.json](RAG_UNIT_PLANNER_JOURNAL_RESULTS.json)へ記録した。旧v3 source/journal hashと4runlockを保持。

24項目の全transport回帰を完了したという意味ではない。HTTP/header/body timeout・decode後のkey反射拒否は次のbounded transport実装単位であり今回未実施。今回の基盤にkey入力口はない。実API/schema受理・モデルの意味品質/費用/latency・実機iPadは未評価。mockの合成reviewは実際の独立意味判定の証拠ではない。

manifestはoffline用。次にtransport/review source境界を変えるときは別manifestを固定し、今回のofflineテストdirectoryを実runへ転用しない。旧4失敗runの再送・解除をしない。次は新bounded transportを実装し、decoded秘密反射・deadline・固定診断のmockと独立安全gateを通過してから実APIへ進む。

Projectの資料の更新: なし。
