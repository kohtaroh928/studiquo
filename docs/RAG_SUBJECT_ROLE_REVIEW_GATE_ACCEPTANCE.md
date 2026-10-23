# 対象role比較：review接続の受入条件

2026-10-16。既承認の[paired設計](RAG_SUBJECT_ROLE_PAIRED_DESIGN.md)を実装する際の確認順。今回は文書のみ。既存stage0 moduleや実runを変更しない。新しい採用基準を追加するものではない。

## 実装する順番

1. 現[packet helper](RAG_SUBJECT_ROLE_PACKETS_REPORT.md)を使って、固定stage名のcollectionを共通lock下で一度だけO_EXCL保存する。全collectionのbyte hashとmapping hashをfile→directory→journalの同期順でpackets_readyへ結び付ける。再呼出でIDを再生成しない。
2. 提出時に同一fdで固定collectionを読み、journalに登録した全byte hashへ照合する。その後、ledgerからpacket/mappingを再検証し、packetId/hashで元のjobを確定する。別collectionが形式上再生成可能でも、登録済みcollectionとの差替えは拒否する。
3. 各armの元reviewを既存の8観点semantic ledgerで個別に採点する。candidateを根拠にbaselineを採点しない。宛先解決済みという理由だけで採点済み・安全な文字列と扱わず、元reviewの型・値・上限・bindingを検証してから保持する。
4. 全armの元reviewと外側job/packet/run/stage bindingをprivate stage artifactへ一度だけ保存し、元reviewから集計した結果をjournalへ記録する。同一plan・同一reviewHashは許容するが、packetId/hashごとの提出と実監査は必要。
5. 再open時と次の予約直前に、全先行collectionと元review artifactを読み直し、再生成・再採点する。保存済みdecision/summaryだけで継続しない。
6. 上記が検証できた後で、新しい全stage用manifest/replayを接続する。現在のstage0専用台帳・保存manifestを拡張済みと見なして再利用しない。transportはさらに後の別gateで接続する。

## stageの比較継続判定

前提は当stageの全jobが技術完了していること。HTTP/timeout/refusal/形式/秘密反射/保存不明は意味採点へ置き換えず技術停止する。

| baseline | candidate | 結果 |
| --- | --- | --- |
| reviewed_match・reviewComplete・全要求representable | 同条件のreviewed_match、missing/extra上下限0 | 比較continue可 |
| 確定mismatch_detected・reviewComplete・全要求representable | 上と同じcandidate適合 | baseline不適合を保持して比較continue可 |
| pending・uncertain・unsupported・review不足 | 適合 | stop、未知を誤りへ変換しない |
| 適合または確定不適合 | mismatch・pending・uncertain・unsupported・review不足 | stop、候補合格としない |
| 一方でも技術未完了・保存不明 | 任意 | 技術停止、片側補完や再送なし |

reviewCompleteは既存semantic ledgerの定義を使う。正しい一対一対応がすべて承認された場合、不要なcross-pairまで採点することを新たに強制しない。表現可能性は別に全要求を確認し、対象不在やunknownを母数から除外しない。continueは比較実験の継続であり採用・releaseではない。

## 接続時の追加回帰（予定、未実行）

- 同一ledgerから異なるIDで作った別collectionは、単体helperで形式合格でも、登録済み全byte hashに一致せず受付不可。
- collection作成後・packets_ready書込前の故障は孤立状態として停止し、上書き・自動再登録・ID再発行をしない。
- packets_readyだけでは次stageの予約不可。元review/必要armの不足、重複提出、別stage提出も予約0。
- 同一plan/同一reviewHashの両版は許容し、混ぜたpacketId/hash・別版job binding・改変mappingは受付不可。
- 上表の全組合せとreviewComplete/representabilityの違いを、実際のsemantic ledger出力から検証する。呼出元のcontinue要求だけでは許可しない。
- review JSONの余剰field、無効enum、未知task/requirement、byte超過、質問/plan/oracle binding不一致は保存前に拒否する。本文/causeをdiagnosticへ含めない。
- 全先行collection/artifactの欠損・byte hash不一致・mode/link変更・source変更は次の予約前に拒否する。同一open handleの保持中や読取前後の同byte別inodeへの差替えも拒否する。再openをまたぐ同byte・正規権限のinode置換まで検出するとは保証しない（初回dev/inodeの永続固定は現設計の対象外）。
- review artifact保存中のshort write/fsync/close故障を不確実停止にし、成功応答や二重terminalを作らない。
- prefix停止時はbaseline/candidateの技術完了数、技術完了pair、比較可能pair、予約済み/未予約pairを分ける。予約を実送信証明にせず、未評価後半を全12問の改善率へ外挿しない。

現時点ではこれらの接続回帰は未実施。直近の全Worker1,590成功はpacket helperまでの結果であり、今回再実行していない。次回実装時に独立コード/安全レビューを行う。人間gold pending、本番v1・未使用20問・旧5停止runを保持。Projectの資料の更新: なし。
