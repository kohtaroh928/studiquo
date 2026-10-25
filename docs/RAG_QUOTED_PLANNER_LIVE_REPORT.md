# Quoted planner v3：有限transport統合

2026-10-15。[High設計](RAG_QUOTED_PLANNER_LIVE_DESIGN.md)に沿って新 `quoted-task-planner-live.mjs` と送信機能のない `quoted-task-planner-review.mjs` を追加した。旧offline journal/source/testは `baselines/20261015-quoted-journal-offline/` へ保存し、旧結果のhashを変更しない。journalはmanifest version2・新suiteId・transportAttached:trueへ移行し、live/review sourceも固定した。旧offline準備journalを新runへ転用しない。

固定8問/1+3+4段階、stage60/180/240秒、request60秒、先行予約8192microUSD/件（累計65536）、body24KiB/response256KiB/plan32KiB、redirect:errorを維持する。review待ち/全完了時は送信0。quote/formal validation後も意味監査が次stageのgateで、監査の実在は信頼した呼出元が成果物を確認して登録する。

保存前はjournalの履歴再検証後にもdeadlineを確認し、fsync後に期限を超えた場合も成功扱いにしない。この場合に物理的なcompletedが見えても監査停止としてlockを保持し、failedを重ねない。同期I/OそのもののOS停止をリアルタイムに中断する保証はなく、帰ってきた後に超過を検出して止める。

失敗はphase/HTTPstatus/有限reasonだけを記録し、上流本文やmessage/causeを出さない。キー反射、UTF8/Content-Type/累積byte、headers/bodyのdeadlineとcancelを確認する。初失敗で後続停止し自動再送しない。キーloader/CLI/ログ/自動起動は新moduleに含めない。

対象transport10・journal12テスト成功。固定1+3+4・監査待ち0送信・8件後0送信・review stop・HTTP/usage/refusal/曖昧/不一致・秘密反射・巨大/不正UTF8・headers/body停止・予約fsync失敗/時間超過・保存直前超過・completed同期障害・同時実行/通知例外・未知引数を確認した。全Workerと独立レビューは完了後追記する。

現時点で実API送信0。mock成功はAPI schema受理や実モデル品質を保証しない。独立安全gate通過後、実行直前の公式料金を確認し、新manifestの第1段階だけを最初に実行する。旧3runの解除・再送なし。意味監査を通らなければ後続7件を送らない。Projectの資料の更新: なし。


## gate通過と第1段階

transport11/journal12、全Worker1,425成功（失敗/skip0、45.1秒）。独立コード/安全各22テスト成功・High/Mediumなし。その後コードを変えず、completed/stage_finishedのfsync期限超過・stage_finished同期失敗の直接回帰を追加して成功した。

2026-10-15に[公式Luna料金](https://developers.openai.com/api/docs/models/gpt-6-luna)を実際に開いて再確認：Standard/1M tokenあたりinput0.10/cached0.01/cache-write0.125/output0.50 USD。予約計算を維持。新fixed path `/private/tmp/studiquo-rag-quoted-v3-20261015-01` で新契約の第1段階1問だけを開始した。旧3runは解除/再送せず、後続7問は意味監査前に送らない。結果を追記する。


## 実API結果：4試行で停止

第1段階index0は成功し独立監査continue、実成果物 [RAG_QUOTED_PLANNER_STAGE0_AUDIT.md](RAG_QUOTED_PLANNER_STAGE0_AUDIT.md) のhashをreview recordへ登録した。独立値2項目/対象属性対応/unknown保持を確認。広いrequestSpanによる厳密注釈一致0は、意味誤りではない。

第2段階はindex1/2成功、index3でHTTP200/validation/quoted_task_planner_quote_not_foundにより停止。4予約/3完了/1失敗、後続index4..7は未送信。引用textまたは直前prefix/直後suffixの完全一致候補がなかったことまでは分かるが、どのfieldや文字が誤ったかはpayload非保存のため不明。数字offsetをAIに数えさせる経路は除いたが、引用/context選択の安定性は未達として扱う。

新runは11行、journal SHA256 `70edfaabd3ebeb5ad8d51f1ba139fa1291b66505badf71f1350b5e2e06d26cd4`、lock保持、予約32768microUSD（0.032768USD）を保持。成功3件のusageからの試算だけは約0.00089974USDだが、失敗分usage/請求額は不明で、総実費をこの値や0としない。既知成功の応答時間は約10.97/7.25/8.77秒。元3runのlockを解除せず、別pathでの自動再送も行わない。独立最終監査を追記する。

独立最終監査完了：11行chain/source/jobhash/第1段階artifact hash一致。index1比較1項目、index2別属性の値2項目について対象・属性・操作・unknown維持を確認。代表注釈とのrequestSpan差は妥当。後続4予約なし・lock保持を確認し停止維持とした。3完了を汎用精度や8問成功率に一般化しない。
