# v4有限評価：通信統合と模擬確認

2026-10-15。通常使用枠の回復を確認して承認済み作業を継続。[設計](RAG_UNIT_PLANNER_LIVE_DESIGN.md)に沿う新bounded transportを追加した。本番v1、未使用20問、旧v2/v3/通信なしv4基盤を変更しない。

## 実装

- 新`unit-task-planner-live.mjs`：固定HTTPS Responses POST・redirect:error、固定8問1+3+4・stageごとの独立意味review待ち。request32KiB/response256KiB/plan32KiB、60秒と各stage60/180/240秒のdeadlineを短縮だけ許可。予約fsync後に送信し、初失敗・保存不確実時は後続停止、lock保持。timeoutでheader/bodyをabort/cancelし、自動再試行しない。
- 新`unit-task-planner-live-journal.mjs`/`live-review.mjs`：別suite/manifest v2/transportAttached:trueに16source hashを固定。通信なしv4のmanifest/ソース/テストを保持し、旧offline directoryをliveへ転用できない。全先行stageの元review artifact再評価は予約前にも必須。
- 秘密反射guardをrequest JSON・raw response JSON・最終parser結果の保存JSONの3箇所に接続。2段のJSONやUnicode escapeで隠れたkeyも、復号したplan/provenanceを保存する前に拒否する。一般DLPや本人認証ではなく指定keyの文字列検査である。
- 診断はfetch/body/validation・HTTP status・有限reasonのみ。上流例外/本文/秘密を保存しない。保存が始まった後の障害へfailedを重ねない。generationCompleteとfinalReviewCompleteを区別する。

## 検証

live15件+journal21件の36件成功。固定stage予約・独立review・完成後送信0・stop・HTTP/usage/refusal/role拒否・body/UTF8/サイズ・header/body timeout・保存前後の期限・fsync故障・同時入口・進捗callback失敗・selector上限拒否を確認した。

追加回帰でUnicode escapeのouter/property・2段JSONのinner labelを保存前拒否、stage0 artifact削除後stage2の予約/送信0、旧offline manifest拒否、requestのkey衝突でdirectory作成前停止を確認した。secret guardを含む43件も独立安全レビューで成功。全Worker1,540件成功、失敗/skip 0。独立コード最終36件も成功、独立code/安全のHigh/Medium残件なし。最終manifest/source/test hashは[RAG_UNIT_PLANNER_LIVE_RESULTS.json](RAG_UNIT_PLANNER_LIVE_RESULTS.json)へ記録した。

模擬fetchは外部へ接続せず、資格情報は合成test値のみ。実API/schema受理・実モデルの要求抽出品質・応答時間・実費は今回未確認。モデル精度をテスト成功件数から算出しない。oracleの人間確認pending、reviewer本人性はworkflow依存のまま。

## 実行前に残ること

旧4失敗runを再送/解除しない。実行直前に公式Luna料金と料金仮定、固定新directory未使用、最終manifest/source hash、予算8192microUSD/件・全65536microUSD（実請求上限ではない）、通常使用枠を確認する。その後は新runのstage0の1問だけを評価し、実成果物の独立8観点reviewが通った場合だけstage1/2へ進む。途中失敗時は同run停止とし別path自動再送をしない。

今回API送信/実キー読取0、deploy/migration/pushなし。Projectの資料の更新: なし。
