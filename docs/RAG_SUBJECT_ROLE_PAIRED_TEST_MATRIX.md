# 対象role paired比較：予定回帰matrix

2026-10-16。実装前の予定。[設計](RAG_SUBJECT_ROLE_PAIRED_DESIGN.md)参照。今回これらのpaid runner回帰を実行したという意味ではない。

| # | 条件 | 必須結果 |
| --- | --- | --- |
| 1 | 全job manifest | 12pair/24送信、偶奇順、checkpoint2/8/16/24、予約196608固定 |
| 2 | stage0正常 | 2送信だけ、両armを記録してreview待ち |
| 3 | baseline確定不適合/candidate適合 | 全レビューcomplete/representableなら比較continue。baselineを修復しない |
| 4 | baseline pending/unsupported | stop。未知を不適合にせず比較継続不可 |
| 5 | candidate不適合/未確定 | 次stage送信0、未評価後半を分ける |
| 6 | baseline/candidateのHTTP/timeout/形式拒否 | 即全後続停止、意味不適合としてcontinueしない |
| 7 | pair片側のみ技術完了 | partialPair保持、comparableへ数えず補完再送なし |
| 8 | requestHash/variant/ordinal/pairIndex不一致 | 予約/送信/parse/replayで拒否、別版fallbackなし |
| 9 | 同じplanでもpacketId/hash・外側armが不一致/packet mapping改変 | 提出時bindingで拒否。同じ判定内容/reviewHash自体は許容 |
| 10 | all arm review不足/重複/別stage/別question | gate拒否、送信0 |
| 11 | 過去stageのartifact/packet欠損・差替 | live自身の全先行再評価で予約/送信0 |
| 12 | 同時live/review・packet/孤立artifact・fsync/close故障 | 共通lock、O_EXCL、packets_readyの同期順、不明状態停止、二重terminalなし |
| 13 | secretのraw/Unicode escape/2段JSON反射 | request/rawresponse/final保存対象を検査し本文非保存で停止 |
| 14 | header/body停止・parse/再検証/保存前後deadline | abort/cancel・後続0、時間拡大override拒否 |
| 15 | UTF8/content-type/redirect/累積byte/JSON異常 | 固定phase/status/reason、本文・cause非保存 |
| 16 | review/全stage artifact/journalサイズ・権限/link/inode異常 | 同一fd検証と上限で拒否 |
| 17 | usage不正/未知cache区分/失敗usageなし | 拒否または実費不明、予約と請求/既知分を分離 |
| 18 | prefix停止/最終終了 | 両版件数・partial/comparable/planned数、generation/review/candidate合格を別表示 |
| 19 | 旧8問run/旧manifest/source混在 | 拒否、旧5lock/hash保持・新path自動再送なし |
| 20 | import/packet/review/replay | 鍵/通信0。oracle/期待role/reviewを送信bodyへ混入しない |

| 21 | packets_readyだけでlive再呼出 | packet準備は比較continueではない。送信0のreview待ち |

source hash/role名は上流実行証明・本人認証ではない。人間gold pending、本番v1/未使用20問保持。Projectの資料の更新: なし。
