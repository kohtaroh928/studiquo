# v4有限評価：回帰matrix

2026-10-15。[設計](RAG_UNIT_PLANNER_LIVE_DESIGN.md)の実装時に確認する。今回は予定であり実行結果ではない。

| # | 条件/操作 | 必須結果 |
| --- | --- | --- |
| 1 | 新規run stage0 | reserved fsync後にindex0だけ1送信、stage終了後review待ち |
| 2 | review待ち/全生成完了でlive再呼出 | 送信0、generationとaudit完了を分離 |
| 3 | 全caseの独立reviewed_match | 正しいstage/hash/artifactを保存後だけ次の3/4送信許可 |
| 4 | review case不足/余分/重複/別stage | gate拒否、送信0 |
| 5 | review pending/unsupported/uncertain/欠落/過剰 | stop、母数から除外しない、後続不可 |
| 6 | review hash/role/run/checkpoint/source/oracle改変 | live入口自身が全先行stageを再評価/照合して拒否、送信0 |
| 7 | artifactなし/改変/任意path/symlink/サイズ超過/読取中inode差替 | 同一fdの検証済みbyte列でgate/live再検証拒否、送信0 |
| 8 | review artifact O_EXCL作成/同時review/各fsync/record途中故障 | 共通lockで保護、上書き/再登録なし。孤立artifactは監査停止 |
| 9 | 保存planとprovenance/hash不一致 | 固定質問から再生成で拒否。保存provenanceを信用しない |
| 10 | 別questionHash/旧v3/未知ID/長いlabel/偽support | 固定parser reasonで停止、repairしない |
| 11 | 正しいIDで架空label/誤role/結合task | 形式pendingのまま、独立意味gateで不合格を保持 |
| 12 | 同時入口/既存lock/未完了reserved/failed/tail破損 | 送信0。lock解除/別dir再送をしない |
| 13 | manifest/job/limits/source/body hash不一致 | 予約・送信前に拒否 |
| 14 | 32KiB body超過/旧24KiBへの差替/予算上限override | 拒否。固定新manifestだけ使用 |
| 15 | 通信前reserved書込/短いwrite/fsync故障 | 送信0、状態不明ならlock保持 |
| 16 | header停止/body停止/parse後/保存前後のdeadline | timeout/監査停止、bodycancel、後続0 |
| 17 | 応答超過/不正UTF8/非JSON/redirect/HTTP異常/refusal | 固定phase/status/reason、本文非保存、後続0 |
| 18 | request key混入/raw・Unicode escapeのresponse key反射/悪意あるerror cause | 復号後の保存対象も検査し秘密の保存/echoなしで停止 |
| 19 | usage欠落/不正/上限超過/未知cache値 | 固定拒否。失敗実費は不明、予約と実費を混同しない |
| 20 | completed保存/close/lock解除/directory同期故障 | 二重terminal appendなし、不明run再利用不可 |
| 21 | import/manifest/replay/review呼出 | API/鍵読取0、任意本文logなし |
| 22 | 正常8生成と最終review | 生成8と全意味監査完了を別計数。human gold/release未承認維持 |
| 23 | stage0 artifact削除後stage2 live起動 | 全先行stage検証により予約/送信0 |
| 24 | 旧v2/v3 source/journal/4runlock | 凍結hash/存在を維持、新codeから自動再送しない |

traceability: reviewHash/artifactHashは内容追跡用で本人認証ではない。形の検証と意味評価と本番採用を分ける。今回テスト再実行/API送信0。Projectの資料の更新: なし。
