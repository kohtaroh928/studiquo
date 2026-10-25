# 原PDF解析結果から新Notebookへの採用設計

2026-10-18。次工程の独立Planner調査結果。**設計案であり、この文書のreceipt・registry移行・結果転送は未実装**。先行する停止再試行の実装とは分ける。

## 2026-10-19 現在地の補正

以降の「結果転送未実装」は作成時点の記録。現在は通信中だけ保持するNDJSON転送と最終completeを実装し、実Linux＋local workerdで確認済み（remote/iPad未接続）。receipt/registryへの正式採用は引き続き未実装。保存期間と削除の制約は[RAG_PDF_RETENTION_DESIGN](RAG_PDF_RETENTION_DESIGN.md)を参照し、分散commit未解決のreceiptを一律TTL削除しない。

## 現在の接続点

`pdf-process.js`は受付枠を保持したままstrict manifestを非公開consumeResultへ渡す。consumer終了時に参照を落とし、実task/VM終了を確認して精算し、小さいjob ID/consumed状態だけを返す。精算後にmanifestをそのまま返す変更は、メモリを持つ処理の受付枠を先に解放してしまうため採用しない。

iPad側は`RAGStructuredAttachment.importNotebook`でPDF/manifest digest・全ページを検証し、`RAGStructuredDocument`で実text sourceHashを計算する部品がある。`RAGLibrarySyncService`はNotebook検証→text registry prepare→構造payload送信を担当する。これらを再利用する。

0011のregistry INSERT triggerは同documentのintakeを取り消す。この境界を弱めず、採用成功時はintake認可からregistry認可へ明示的に切り替える。

## 次の最小実装単位

まず本文保存や公開routeを増やさず、非本文の採用契約と原子的なregistry移行を合成データで検証する。

1. intake document IDを将来のNotebook.ragDocumentIDとして固定する。タイトルやページ数で既存Notebookへ推測対応付けしない。intake generationとregistry generationは別管理。
2. trusted manifest validatorから、job/intake/対象document ID、両epoch、原PDF digest、manifest hash、実text sourceHash、全page数を確認する。client自己申告を採用許可としない。ownerは認証session由来。
3. 精算済みjob、最新intake、account、両同意、期限、対象registry不在を再確認し、receiptとregistryを一つのDB transactionで作る。片方だけ成立したらtransaction内でabortし、JSのchanges確認だけで代用しない。
4. 同一receiptの再送は同source/registry generationへ収束する。registry INSERT後は旧intake guardを呼ばず、receiptと現在registryのowner/source/generation/text hashを確認する。triggerのintake取消を正常な権限移行として扱う。
5. 通常LibrarySyncが採用直後に別generationへ置換しないよう、同期状態へ同じregistry証明を渡す。

受入試験: 取消/epoch変更/削除と採用の競合、二重採用、同IDの既存文書、triggerの正常失効、receipt/registry片側失敗のrollback、他owner/旧intake拒否、再送時の世代固定。新しい有料評価や実資料は不要。

## 結果の保持・転送は次の設計境界

metadataの証明だけではmanifest本体をiPadへ渡せない。次のいずれかを具体化する必要がある。現在どちらも有効化していない。

| 方式 | 利点 | 実装・制限 |
| --- | --- | --- |
| 通信中だけ保持 | 新しい本文保管場所を増やさない | 送信終了/取消確認まで受付枠を維持。有限の転送期限と受信上限が必要。切断後の同結果再取得は保証できず、同intakeを無条件再解析しない |
| 暗号化した短期保管 | 切断後も期限内の再取得を設計できる | 別途、保存先/鍵/期限/失効時削除/認可/料金/障害時後片付けが必要。保存・外部影響を含む具体案をレビューしてから接続する |

現行のconsumer終了時参照解放とstorage追加なしを両方維持したまま、後で本文を再取得できるとは説明しない。実Linux/VM検証と上のmetadata単位を先に進め、本文の保持方式を確定した後に転送契約を変更する。

## iPadの正式保存

同一PDF＋manifestを既存Swift validatorへ通し、未挿入Notebookを生成する。account/endpoint/両epoch/対象intake/取消を再確認してから保存する。SwiftDataとサーバーregistryは分散commitなので、片側成功・再起動・通信断に冪等receiptと補償手順が必要。正式保存前はホーム検索へ出さず、失敗時に通常同期で別文書を作らない。

原PDF公開API、本文保存、外部送信、iPad保存をこの設計作成だけで承認・実施したとは扱わない。ロールバックは採用入口を閉じ、失効/receipt/世代の記録を保持する。既存prepared package取込と旧Workerは維持する。
