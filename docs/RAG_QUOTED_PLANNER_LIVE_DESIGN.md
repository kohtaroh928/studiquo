# Quoted TaskPlan v3の有限API評価設計

## 目的・現在地

2026-10-15。[v3入出力](RAG_QUOTED_PLANNER_IO_REPORT.md)を実APIで確認する前のHigh設計。前段の全Worker1,402成功はコード検証であり、v3のAPI schema受理・モデル完了率・意味品質は未評価。この文書の作成だけではAPIを実行しない。ユーザーの継続開発・評価の承認範囲で実装/mock/独立安全確認を進め、通過後だけ有限評価へ進む。追加購入・キー/モデル変更・旧run再送はしない。

## 固定範囲・上限

- 新しい `quoted-task-planner-live.mjs` のみで、固定開発8問をindex0..7の順に各1回。quoted v3 request/responseを使用する。任意question/model/variant/body/selectorを受け付けず、本番へ接続しない。
- 段階は **1 + 3 + 4**。完了checkpointは1/4/8。入口1回につき1段階だけで、自動で次段階を実行しない。第1段階はschema受理・quote位置解決・対象/属性対応・独立値の分割を独立監査してから次へ進む。後続段階にも記録と監査を挟む。stage_finishedだけでは次へ送れず、直前checkpointに結び付いた独立review_passed記録を必要にする。
- 1送信の予約8192microUSD、全8送信65536microUSD（0.065536 USD）。これは既存入力32768token・出力8192tokenの保守的な予約計算で、実請求額ではない。実行直前に公式料金率を再確認する。入力量/キャッシュ区分の既存仮定が変われば、送信せず見直す。旧失敗runの予約とは別に記録する。購入や残高リセットを行わない。
- 本文24KiB・応答256KiB・plan32KiB・1送信60秒・各段階はそれぞれ60/180/240秒以内。タイムアウトはheaderだけでなくbody読取とparse/保存直前までを含める。上限を広げる引数を許可しない。
- model/settingsは凍結v3入力通り。Luna/medium/default/store:false/stream:false/max_output8192。本番v1、未使用20問、手書きoracleは送信しない。

## 永続化・送信制御

1. 新suiteId/contractVersion3、8jobのrequestHash/questionHash、関連する全境界（runner・request・response parser・quote resolver/schema・元v2最終validator・親request・固定fixture）のsourceHash、段階/費用/時間/サイズの上限を固定manifestへ記録する。既存v2/paired runnerとsourceとjournalは変更しない。新契約の評価であり、旧不明失敗を再送で埋めたり旧品質比較を完了扱いにしたりしない。
2. 新canonical absolute directoryを使う。owner/mode（directory0700・file0600）、symlink/hardlink/inode、排他的running.lock、journal hashchain、最大1MiB、write長/ファイルとdirectoryのfsyncを確認する。最初のmkdirは排他的。既存dirの再開は同じmanifestの正常checkpointからのみ許す。
3. 各jobでreservedをdurableにしてからdispatch。再開時にmanifest/全record/quoteとresolved planの対応/requestHash/usage/checkpointを再検証する。保存quotedPlanだけを再計算入力にし、固定質問からv3を再解決した結果が保存resolved planと完全一致することを確かめる。保存resolved plan自体を再計算の入力にしてquote側の整合を飛ばさない。異常・tail欠損・reserved未完了・failed・lock残存なら送信0で停止する。
4. 成功時はquotedPlan/解決plan/usage/model/responseHash/expected requestHash/elapsed/意味監査pendingをprivate journalに保存する。raw response、prompt、キー、実学習内容は保存しない。quotedPlanと解決planの引用は固定合成資料だけで、共有RESULTS/Notionへ転記しない。requestHashは期待入力の識別であり上流送信の暗号学的証明ではない。
5. 正常stage_finishedをdurableにし、close後にのみlock解除。解除後のdirectory同期失敗時はlock再作成を試すがbest effortであり、OS障害下で永続lock保持を保証しない。状態の不明なdirは再利用不可とする。完了後の同runは送信0。書込/close/lock解除や同期に失敗すれば監査停止とし、自動解除しない。
6. 段階レビューは通信を持たない別入口で、正常stage_finishedとそのjournal hashに結び付ける。実際の独立監査の完了後だけ、固定stage番号・完了件数・checkpointHash・manifestHash（source/request/run binding）・固定review担当種別・本文を含まない監査artifactHash・固定decisionをappend/fsyncする。任意のレビュー本文はjournalへ受け付けない。run入口は直前review_passedなしでは次stageを送信0で拒否する。review_stopがあれば後続不可とする。ローカルhash/記録は人間・エージェントの実際の独立性を暗号学的に保証しないため、workflow上の独立レビュー証跡も残す。
7. 初失敗で全後続停止しlock保持。新pathで同じ入力を自動再試行しない。stage終了後のレビューを通過した場合だけ次stageを起動する。失敗runを完了扱いにする履歴補正はしない。

## 通信・秘密・失敗診断

固定HTTPS Responses URLへPOSTしredirect:error。既存キーloaderは実実行入口だけから利用する。新moduleは自動実行/CLI/env読取/ログを持たない。送信前bodyへのキー混入、受信bodyのキー反射を検出して停止する。Content-Type、UTF8不正、累積byte、bodycancel/deadlineを検証する。

失敗記録は固定phase（fetch/body/validation）、HTTPstatus（100..599/null）、固定reasonのみ。新v3 parserのquote_not_found/quote_ambiguous/quote_shape/invalid_plan等は有限allowlistで採用する。上流error.message/cause、原文、context、offsetは記録しない。保存中エラーに重ねてfailed recordを書かず、不明送信として残す。失敗usage/実費は不明とし、ゼロや既知完了分の合計で代替しない。

## 監査・評価と受入条件

- コード：固定8/max1+3+4、予約fsync先行、同時実行拒否、再開/完了送信0、改ざん履歴、binding、失敗時停止、timeout、byte上限、秘密反射、fsync/close/解除故障をmockで回帰する。既存runnerの検証水準を維持し、v3専用再検証とstage差を確認する。
- 独立レビュー：実装前Planner、実装後Code ReviewerとSecurity Reviewer。High/Medium未解決ならAPIへ進まない。
- 実行後：chain/source/job hash/予約/lock/送信件数を監査。形式成功と意味成功を分ける。既存手書きoracleとの厳密span一致は注釈一致に限定し、意味精度と同一視しない。人間goldは引き続きpending。
- 意味監査：対象・属性・操作・条件・要求項目の漏れ/過分割、独立値と比較/共同要約、根拠unknown維持を別項目で確認する。必須scopeの欠落・結合・対象誤対応・条件role未達があればreview_stopとして次stageを保留する。妥当な別spanだけを理由に意味不合格にせず注釈差として扱う。8件の生成完了と最終意味監査の完了を別々の状態で表示する。成功planの自己申告を採点根拠にしない。失敗quoteがあれば原文を記録せず固定拒否条件の範囲だけを述べる。
- 旧v2の全8対照結果が揃っていないため、このrunだけでv2より何%改善したとは報告しない。RAGの回答/検索/100ページPDF/iPad品質とは別の評価。

## 障害・停止・ロールバック

HTTP/usage/schema/refusal/quote/timeout/秘密/保存のいずれの障害でも後続停止。既知完了分だけのusageと時間、予約額、実費不明を分けて報告する。再開可否を推測してlockを消さない。runnerを利用停止すれば本番は変わらない。新runtime/DB/migration/deployは不要。schema不受理・意味品質不十分なら設計へ戻し、未知のモデル/キー切替で回避しない。

独立Planner/安全レビュー完了。Plannerのstage監査gate具体化指摘を反映し、監査の固定schema/binding、進退基準、最終意味監査との状態分離を追記した。安全レビューの再計算入力/source境界/stage時間/異常予約保持/偽履歴テストを反映した。未解決High/Mediumなし（実装の安全性・品質合格ではない）。

現在は設計だけ。予算上限と停止機構の実装・mock・実装後の独立安全確認・実API評価は未実施。Projectの資料の更新: なし。
