# Step6-B：実PDF処理への停止証拠接続

2026-10-19。`codex/rag-wip`、基底commit `4debcd4`。Step6-AとProject同期の既存dirtyを保持した追加実装。remote配備済みの状態ではない。

## 結果

PDF処理が実際に終了して証拠を保存できた場合に、実行tokenを失ってもreaperが利用枠を精算できるようにした。reader・検証・parse・manifest検証・consumer・monitorの実taskを追跡し、timeout wrapperの完了を停止と混同しない。成功／失敗の両方でmonitorと実task、reader cleanupの終了を待ち、payload/readerTask/Request参照を解放してからlocal証拠を保存する。遅い完了がcleanup graceを過ぎた場合は後から証拠保存や精算を再開しない。

新protocolは`RAG_PDF_STOP_EVIDENCE_ENABLED=true`のときだけ選択し、schema不足時はlegacyへfallbackしない。flag falseは既存経路を維持する。flagは配備設定へ追加・有効化していない。既存の暫定NDJSON転送は維持し、terminal成功は精算と最終認可の後だけ。最終認可はseal済scopeから分離した有限metadata確認である。

成功parse後もtrusted cancel adapterの厳密なackからremote証拠を記録する。同一cleanup中のcancelは一度だけで、失敗をcatchで再送しない。各段階は同じcleanup graceの残時間を共有する。未dispatchはlocal証拠＋DBの未dispatch状態で0units、dispatch済みは予約units全額を精算する。これは実API請求額の校正ではない。

## reaperと競合

新証拠schemaが存在する場合だけ、同一job/claim/protocolに結び付いた保存済み証拠を最大10候補で精算する。remote停止は既存attempt/lease/backoff/上限内でtrusted adapterへ分岐し、古いjournalのremote_stoppedだけを新証拠へ流用しない。flags off・同意撤回後もcleanupは可能。証拠完備ならattempt上限後も精算可能で、二重精算や精算時刻の更新をしない。

Codeレビューで、候補SELECT直後に別passがleaseを得るMediumを指摘。精算UPDATEでもlease不在を再検査し、競合は枠を保持するよう修正した。read後のlease注入回帰を追加済み。証拠を保存する前にexecutor自体が消失した場合やlegacyの停止不明jobは引き続き保持する。heartbeatや管理者booleanによる強制解放はない。

## 0017の保存期間契約

0015/0016は変更せず、0017で`pre-adoption-stop-v2`へ更新し、以前のpurge opt-inは0へ戻す。writer fence/admission floor/時計は維持する。最小証拠tableだけを再構築してFK `ON DELETE CASCADE`を加え、既存の全証拠列をそのまま移す。job行は移さず、既存証拠の不変triggerを元の名前で復元する。実remote適用前にはbackup/復旧点・別系統migration照合・適用承認が必要である。

新purgeは既知6 PDF table・未知receiptなし・48h経過・過去UTC窓・永続失効/世代置換・registry参照なし・recovery done/lease完全解除を維持する。新protocolは両証拠とclaim/hash/時刻の整合も必須。legacyは証拠行がない従来精算済みだけを扱う。粗い候補最大10件とcursorで有限に進める。

親BEFORE DELETEが条件を再検査し、floor/contextを更新してrecovery childを削除する。親行の消失後にFK cascadeが証拠childを削除し、親AFTER DELETEがcontextを解除する。childguardには対象contextとactiveleaseに加え親行の不在を要求するため、手動context設定でも証拠単独削除は拒否する。証拠・recovery・親・後続statementの失敗はfloor/lease/cursor/contextを含めてrollbackする。D1 batchの取引契約は[Cloudflareの公式資料](https://developers.cloudflare.com/d1/worker-api/d1-database/#batch)を確認し、実local D1でも検証した。

Securityのcontext偽装Mediumを上記cascade方式へ修正。Codeのcontext解除trigger確認漏れLowも、module・DB guard・診断で両context triggerとFK cascadeを確認する方式へ修正した。0016だけでは旧purgeは閉じたまま。0017後もenabled初期0、HTTP/cronは未接続。将来receipt/adoption導入時は再度契約を更新し、旧purgeを先に閉じる。

## 検証

- 新integration15件と既存回帰を含むserver全体1,923 pass / 0fail / 0skip。
- 処理/consumer/reader cleanupがpendingの間の証拠不成立と枠保持、digest不一致の未dispatch精算、remote失敗後の再停止・証拠精算、精算応答紛失、flags off、schema不足、liveleaseのread/write競合を確認。
- 証拠/recovery/親削除後の失敗で全rollback、手動context偽装拒否、未知PDF/receipt拒否、proof時刻不整合保持、解除trigger欠落拒否を確認。
- 0016上で実processorが保存した両証拠を含む状態から0017へ移行し、証拠/job全列の完全一致・writer fence保持・旧opt-in解除・不変制約/FK維持を確認。
- 実local workerd/D1で17migration、processor local証拠・同一cleanup cancel一回・reaper精算・FK cascade整理・cascade失敗rollbackに成功。一時DBは終了時破棄。remote cancel/parseは合成adapterで実Docling/VM検証ではない。
- 初回integrationの4失敗は合成取消fixtureがdigest/長さをNULLにしていなかった制約違反で修正。初回runtimeは検証scriptのbytesハッシュ生成誤りでcancelまで到達しなかった。実装を弱めずfixture/scriptを修正して再実行成功。最終全suite成功と区別して記録する。
- Planner/Code/Security独立レビューを実施し、上記Medium2件/Low1件を修正、最終再レビュー残所見なし。reviewerによる独立テスト・実D1操作はない。diff check成功。

再現scriptは`mcp-server/tools/rag-pdf-stop-integration-local-smoke.mjs`。件数と今回9source hashはRESULTSを参照。Step6-Aなど過去のhash/成績は当時の版として変更しない。テスト成功をRAGの回答精度改善と解釈しない。

## 残件とrollback

Step6-A/Bのローカル接続は完了。停止証拠前のexecutor消失の自動解放は提供しない。次はStep5-C account削除のPDF pending checkpoint/他phase継続/最終判定。その後DO有限tombstone/receipt、実運用の並列数/メモリ/費用校正、remote/iPad正式採用は残る。0017接続後の実Docling/VM通しとremote障害試験は未実施。

rollbackは新claimとpurge入口を閉じ、0016/17と証拠/FK/trigger/writer fence/floorを残す。schemaを落としたり、旧writer/旧purgeへ戻さない。公開設定/HTTP/cron/キー/モデル/本番状態/有料APIは変更なし。commit/pushなし、automation PAUSED。
