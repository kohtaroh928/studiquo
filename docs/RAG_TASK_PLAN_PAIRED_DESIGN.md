# 要求分解の一般規約候補と対の開発問題

2026-10-15。初回Luna6問の独立意味レビューで判明した、独立値要求の結合と条件role未達を対象とする。これは改善候補の設計で、モデル精度の改善実績ではない。現行request/最初の6plan/結果/source hash、本番v1を変更しない。

## 候補の一般規約

- 独立の値を求める場合は、明示された対象×属性×適用状況ごとの回答枠を保持する。同じ属性でも対象別/状況別の値を求めれば別scopeにする。
- 比較は対象間の関係を答える要求なので、1属性の比較を対象ごとに二重化しない。異なる属性または明示された比較観点を求めた場合は分ける。複数資料をまとめる要約は、資料数だけで分けない。
- attributeは答える対象の属性/概念/関係を示す質問中の語句とする。疑問語や依頼の動詞だけで対象属性を置き換えない。比較方法の説明を、比較実行の要求と取り違えない。
- 原文に明示された適用状況はconditionsに保持する。語句をattributeに含めただけで条件roleを満たしたとはしない。ただし、説明/条件を問う対象概念と、回答全体への状況条件は別なので、機械的にすべてをconditionsへ移さない。
- 原文spanにない属性/対象/条件は作らない。引用が曖昧なら曖昧さを残す。resolution/evidenceSupport/comparisonPermissionはunknown。要求分割ができたことと、資料から答えられることを分ける。

この案は固定model指示へ未適用。既知6問の語句・製品名・IDに分岐する処理は加えない。分割数がoracleと同じだけでは合格としない。

## 新しい開発用8問

`mcp-server/scripts/rag-quality/task-plan-paired-draft.json`に、対になる8問と計13scopeの手書き候補を保存。初回6問・開発30問・未使用20問と別。人間確認pending、UTF16 offset/許容spanは次の注釈工程で独立確認する。モデルには未送信。

| 対 | 正の確認 | 過剰修正の確認 |
| --- | --- | --- |
| 対象ごとの値 / 比較 | 2対象の定員値を別scopeで保持 | 定員の比較は両対象を持つ1scope |
| 複数属性 / 方法の説明 | 開館時刻と入館料を別scope | 比較方法の説明は比較実行にしない |
| 状況ごとの値 / 条件そのもの | 通常/休業中の期限を状況別scopeへ | 条件・例外の対象概念を無差別にconditionsへ移さない |
| 要約 / 明示された比較観点 | 複数資料の共同要約は1scope | 相違点/共通点は別の比較scope |

模範回答や資料の正解値は作らず、質問の要求だけを扱う。語の引用とroleの妥当性が複数ある場合、厳密注釈不一致と意味的未達を分ける。初回6問での厳密span一致0を、精度0%として調整しない。

## 検証と次の工程

新fixtureのJSON整合、8問/13scope、合成/開発/pending/未評価の表示、原文への属性/対象/状況語の存在をローカル確認する。独立レビュー後に、roleの曖昧さを整理し、許容注釈を固定してから候補requestをオフライン作成する。新しいAPI実行はまだ準備しない。候補を将来比較する場合は元案との同一問題比較と過分割を別に評価し、既存の費用/先行予約/初失敗停止を維持する。

今回は設計と手書き候補データのみ。本番/送信処理/既存schema/oracle/キー/DB/flags変更なし。追加API0。直近のWorker全1,350成功は前段の結果で、この8問の抽出精度を示すものではない。Projectの資料の更新: なし。


独立レビューを依頼したが、reviewerがSelected model is at capacityで実行できず未完了。モデル/アカウントを変更せず次回へ引き継ぐ。ローカルJSON整合と8問/13scope/原文語句の存在だけを確認済み。review済み・モデル精度確認済みとはしない。実装コード変更がないためWorkerテストの再実行は行わない。


## 同じ設定でのレビュー再開

次回の同設定レビューは実行でき、8問/13scopeの数え方・roleにHigh/Mediumなし。Low表現を反映し、相違点/共通点は共通の基礎属性に対する二つの比較観点と明確化した。上の混雑による未完了記録は履歴として保持する。

続いて別artifact `task-plan-paired-oracle-v1.json`へ代表的なUTF16注釈を追加した。最初の定員2出現は、それぞれ対応する対象の出現へ結び付ける。既存v2 validatorで8plan/13scopeの形・引用位置・unknown値・自己整合を確認。これは手書き注釈の整合確認で抽出精度ではない。許容される全spanの固定とはせず、妥当な別注釈は独立意味レビューする。新しいspan注釈自体の独立レビューはpending、人間確認もpending。モデル未送信。

## 復帰後の代表注釈・比較入力

通常枠が利用可能になったことと並行作業なしを確認し、同じ設定で注釈レビューを再開。代表8問/13scopeのoffset・対象/状況/依頼対応、定員2出現のP/Q対応を独立確認しHigh/Mediumなし。人間確認pendingは維持。oracle artifact内のpending表記は作成時の記録として保持し、現在の独立確認結果を本書/RESULTSへ追記した。

`paired-task-planner-request.mjs`は固定8問×baseline/candidateだけをオフライン生成する。旧6問requestから設定/schema/元指示をcloneし、質問だけをuser JSONへ入れ替える。candidateだけ一般規約5項目を追記。両版でinstructions以外は完全一致。任意質問/model/prompt/余剰引数は受けず、draft hash/24KiB/clone分離/16request hashを固定。gold/case ID/期待spanは送信bodyに含めない。元6body/元schema/元oracle/初回実評価source hashは不変。

対象4/関連23/独立対象4成功、最終High/Mediumなし。全Worker1,354成功（失敗/skip0）。新しいライブ入口、キー読取、外部送信、料金/予算変更なし。コードテストを8問のモデル正答数としない。候補の効果は未評価で、採用済みpromptへ未適用。

次は新8問に対応したrequest/response bindingを別の独立gateで設計する。旧6問専用parserのindexを流用しない。型検証と厳密注釈一致/独立意味レビューを分け、同一問題・設定の元案/候補比較に既存の費用・先行予約・初失敗停止・未確定再送禁止を接続し、安全レビュー後に限定実評価する。今回まだ実行しない。Projectの資料の更新: なし。

## 新8問の応答binding

`paired-task-planner-response.mjs`を追加。旧6問のparser/source hashは保持し、新8問の固定index/variantから質問と期待requestを求める。完了状態/model/error/incomplete、1assistant text、refusal/tool排除、raw256KiB/plan32KiB、usage整数/合計/上限、元v2validatorによるUTF16引用/unknown/root整合は旧契約と同じ。旧parserと同じ異常応答で固定エラーが一致することも確認。原文/offset/planを補正しない。

同じ質問の同じplanが両variantで形の検証を通るのは正常で、requestHashは選択された期待requestの識別に限る。上流送信の証明や異variantの流用検知を保証しない。実際に何を送ったかは次工程のtransportと先行journalで結び付ける。純parserには通信読取/deadline/費用制御はない。

対象を誤ったroleへ入れても原文quoteが正しければ形は通る反例をテストし、意味pending/releaseAccepted=falseを維持。8×2のモック成功をモデル正答16件とは数えない。対象7/関連18/独立対象7成功、High/Medium指摘なし。全Worker1,361成功（失敗/skip0）。追加API0、キー読取なし、live接続なし。

## 有限比較runの次段階設計案

新8問の元案/候補を同一suite・manifest・private ledgerで管理する。質問ごとに2variantを隣接させ、3対+3対+2対=6+6+4送信の3stageとする。全stageで最大16予約、各8192microUSDの従来予約式なら計131072microUSD（0.131072USD）の案。これは今回の追加購入/送信/予算変更ではなく、実行前に公式料金と上限を再確認する。

- manifestに固定question順/variant順/全16request hashとschema/parser/runner版を保存。任意選択・caller本文は受けない。
- 送信前のreserved書込/fsync、予約後deadline再確認、各60秒/1stage360秒、24KiBrequest/256KiBresponse、secret反射拒否を保つ。
- stage再開は同じledgerだけで、過去予約が全て確実なcompletedである場合に限る。failed/予約のみ/途中行/manifest不一致/不正chain/結果保存不確実なら後続stageも停止。失敗分を別directoryへ移して再送しない。
- 同時実行lock、owner/0700/0600/symlink/hardlink/inode、fsync、全体予約の累積を独立安全レビュー。新しいrunを別pathへ作る運用は承認済み比較範囲の監査を必要とし、アカウント全体のglobal budgetを保証したとはしない。
- 元案/候補の送信順序の偏りを抑える固定順を事前に定める。最初の内容失敗/形式失敗を結果として残し、成功するまでpromptやquoteを直して再送しない。

このHigh単位はまだ未実装/未送信。独立設計・脅威/障害分析・テスト・安全レビュー後に実比較する。本番RAG/回答生成には接続せず、運用上の撤回は評価runを実行しないこと。初回6問と同じく出力本文はprivate、共有記録はhash/件数/usage/注釈IDだけ。Projectの資料の更新: なし。
