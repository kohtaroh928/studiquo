# 対象role比較：bounded transportと3箇所secret guard

2026-10-16。[全24job offline統合](RAG_SUBJECT_ROLE_COMPARISON_REPORT.md)を凍結保持し、別live suiteへ通信層を接続した。今回は**模擬通信だけ**。実API送信・実キー読取・CLI/loader追加は行っていない。

## 追加module

- `subject-role-comparison-live-contract.mjs`：同じ24job/2・6・8・8段階・予約196608microUSDを使う別version2 manifest。live contract/journal/runnerとsecret guardを含む依存closureを固定する。予約は実費・実請求上限・実送信証明ではない。
- `subject-role-comparison-live-journal.mjs`：元reviewの全先行再評価を維持し、予約/完了/checkpoint/closeへdeadlineを接続する。元offline runを受理しない。
- `subject-role-comparison-live.mjs`：明示的なstage関数呼出だけを入口にし、固定Responses endpointへ現stageのみを送る。自動実行・retry・別path救済・モデル/本文/endpoint overrideはない。

公式[Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs)を確認し、schema出力でもincomplete/refusalを別に扱う既存parserの拒否条件を保持した。今回モデル/schema/promptは変更していない。`openai-platform-api-key`ツールは利用可能な一覧にないため使用せず、テストは合成keyだけを使った。

## 送信contextと秘密

全24bodyを事前生成し、期待requestHash・32KiB・secret guardを確認してからjournalを開く。現jobをdurable予約し、そのjobと**実際のserialized bodyから計算したhash**を一つの凍結contextへまとめ、送信/parse/保存で使う。body hashやresponseHashは上流実行の認証ではない。

secret guardを①送信本文、②受信raw JSONを1段復号した全string/field名、③parserを通った最終保存JSONへ適用する。③でoutput_text内の2段JSON/Unicode escapeによる反射も拒否する。keyを本文・journal・進捗・error/causeへ出さない。進捗callbackはordinal/index/variant/件数/stageのみ。非同期callbackは受理せず、rejectionをconsumeして固定errorで停止する。

## 上限と失敗

header/body/parse/保存を1送信60秒以内、stage120/360/480/480秒以内で制限する。timeoutMs/totalMsは短縮だけ。UTF8 strict、受信累積256KiB、JSON content-type、content-length、redirect:errorを確認し、拒否/超過/期限切れでbodyをcancelする。

予約後に期限切れならfetch0。保存前後の期限も確認し、書込不明・保存期限超過で二つ目のterminalを作らずlockを保持する。closeへもdeadlineを渡し、lock解除・directory同期の後に超過した場合も停止markerを復元する。OS故障時の復元はbest effortであり、完全保証ではない。

HTTP/timeout/refusal/形式/secret拒否は初失敗で停止し、任意の上流本文や例外を固定diagnosticへ混ぜない。checkpoint/packet準備済み/全体完了の再呼出は送信0。元reviewで確定した比較continue以外は次stageへ進めない。transportAttached=trueはsuiteの接続状態であり、dispatchAuthorized=false・releaseAccepted=falseを維持する。比較判定は実送信・採用の権限ではない。

elapsedMs記録は保存処理開始時までの時間で、fsync後までの正確な所要時間ではない。成功期限の検証自体はdurable保存・close後にも行う。実測の費用・速度・品質は次の実API評価で別に確認する。

## 検証

対象21回帰：固定24送信と各stageのreview gate、baseline不適合/候補停止、HTTP/throw/partial、byte/content-type/content-length/UTF8/redirect、incomplete/refusal/model/plan/usage、request/raw/Unicode/property/2段JSON反射、header/body timeoutとcancel、予約後/保存中/close解除後の期限超過、fsync不確実時の二重terminal禁止、offline/過去artifact改変の送信0、上限/override拒否、callback停止、live/offlineの全stage判定parity、最終候補不適合の生成/監査/採用分離を確認した。

初期の時計注入2試験は、close故障注入の初期directory同期での早期発火と、1msだけの上限超過がguard処理時間で逆転する問題を修正した。注入phaseと超過幅を明確にし、実装を緩めず修正した。独立PlannerのMedium（同期hash/secret検査後のfetch直前に期限再確認がない）を受け、timerをwork開始前に作り、fetch直前のabort/時刻検査が通った後だけdispatchesを加算するよう修正した。同期secret検査中に時刻を進めるfetch0/timeout/lock回帰を追加し、最終21成功。修正後の全Worker1,659成功（失敗/skip 0）、最終独立コード21・安全21成功。未解決High/Mediumなし。[結果JSON](RAG_SUBJECT_ROLE_COMPARISON_LIVE_RESULTS.json)参照。

## 残件・運用

実API互換性、実モデル品質、実料金/待ち時間、アカウント予算は未確認。実送信前に公式Luna料金・適用条件、新canonical directory未使用、source/manifest、旧5lockをpreflightし、最初の1pairだけを別runで実評価する。独立意味監査の後だけ次stageへ進む。旧失敗/停止runやoffline/mock directoryを再利用しない。

旧全source snapshots・停止journal・本番prompt v1・未使用20問を保持する。アプリ/Worker runtime/DB/migrationへ影響なし。rollbackは新3moduleを呼ばないこと。Projectの資料の更新: なし。
