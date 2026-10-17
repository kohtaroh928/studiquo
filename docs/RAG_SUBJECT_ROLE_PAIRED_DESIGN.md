# 対象role候補：有限paired比較の設計

2026-10-16。High（費用・送信/保存・再開制御）。[固定12問/2版](RAG_SUBJECT_ROLE_CANDIDATE_REPORT.md)を同じoracleで個別に評価する設計。今回はoffline応答parserと設計だけでAPIへ送らない。旧5停止runのlock/ソース/結果を保持する。本番v1・未使用20問は変更しない。

## 応答のbinding

新`parseSubjectRoleTaskPlannerResponse(index,variant,observedRequestHash,raw)`は4引数だけを受ける。固定factoryの期待request hashと、実際の送信bodyから呼出元が得たhashを厳密比較する。別版/別質問へfallbackせず、版名はモデルに生成させない。戻り値にはindex/variant/questionHash/requestHash/responseHashとbindingSource=caller_dispatch_contextを記録する。

モデル応答だけから、同じ質問のどちらの指示を実行したかを認証できるわけではない。hashはtrusted callerの送信contextを結び付けるもので、上流の実行証明ではない。新transportは予約jobの凍結contextを1度作り、送信直前の実body hash・parser引数・保存recordで同じものを使う。

completed/単一assistant output_text/model/usage/byte/strict v4/固定質問からのprovenance再生成を維持。oracle/reviewをparserやrequestからimportしない。形式検証と意味pendingを分離する。既存8問parser/runnerへ黙って置換しない。

## 固定job・段階・上限

- 新suite/manifestで12pair、計24送信だけ。pairのindex0..11は質問ファイルの順序に固定し、偶数はbaseline→candidate、奇数はcandidate→baseline。順序効果を減らすための固定counterbalanceでありランダム実験ではない。
- jobはordinal0..23、pairIndex/index、variant、requestHash、questionHashを持つ。ordinal順以外を送らず、両版は同じ質問/schema/model/設定を使い、差は固定4規則のみ。
- 段階は **1+3+4+4 pair**＝**2/6/8/8送信**。checkpoint completedRequestsは2/8/16/24、completedPairsは1/4/8/12。1入口で現stageだけを実行し独立レビューを挟む。

| 制限 | 固定値 |
| --- | --- |
| 1送信予約 | 8192 microUSD |
| stage予約 | 16384 / 49152 / 65536 / 65536 microUSD |
| 全24送信予約 | 196608 microUSD（0.196608 USD） |
| request/response/plan | 32KiB / 256KiB / 32KiB |
| 1送信 | 60秒以内（header/body/parse/保存前後含む） |
| stage時間 | 120 / 360 / 480 / 480秒以内 |
| journal | 2MiB以内 |
| 元review JSON | 256KiB/arm以内 |
| stage review artifact | 8MiB/各stage以内、固定名最大4個 |
| 中立packetとmappingのcollection | 2MiB/各stage以内、固定名最大4個 |

予約は既存の通常Luna料金・input32768/output8192の保守仮定による計算で、実請求上限でもアカウント全体の予算でもない。実行直前に公式料金・適用条件を確認し、成立しなければ送信しない。失敗usageの実費を0としない。新しい24送信の契約であり旧8送信runとは別。timeout/totalMsの指定は短縮だけにする。

stage artifactは最大8armの元review文字列・binding・結果を保持するため旧2MiBと分ける。JSON文字列への格納によるescape膨張も含め8MiBを上限とする。file/owner/mode/link/inode、同一fdの読取前後stat、累積byte/hashを確認する。不要な大容量本文やraw responseを格納するための枠ではない。

## 比較継続条件（採用条件ではない）

この比較は、**baselineが既知の意味上の弱点を持つか**も測定する。旧v4の「両版全件合格gate」を流用しない。

1. 正常受信・形式/usage/保存検証を通った結果だけ意味比較へ進める。HTTP/timeout/refusal/形式拒否/秘密反射/保存不確実の技術失敗は、どちらの版でも即時全後続停止。baselineの意味不適合と混同して比較継続しない。
2. 各armを同じ凍結oracle/8観点で個別に採点する。candidateを根拠にbaselineを採点しない。レビューpacketは版名・指示を提示せず中立job IDと原質問/plan/oracleを使い、判定後に固定mappingへ結び付ける。sourceや順序の参照による推測は防げないため厳密な盲検とは保証しない。
3. 次stageへ進めるのは、当stageの全armがreviewCompleteかつ全要求representableで、candidate全caseがreviewed_match・missing/extra上下限0、baseline全caseの判定がreviewed_matchまたは確定mismatch_detectedのときだけ。baselineの確定不適合は記録したまま比較継続を許す。
4. baselineのpending/uncertain/unsupportedは比較根拠が不十分なのでstop。candidateの不適合/未確定/表現不能もstop。意味判定はstage終了後に分かるため、これらが見つかったstageの後続stageを送信しない。モデル自己申告でcontinueしない。
5. baselineの不適合はbaselineの結果として保存し、候補の修復やbaselineの補正をしない。role未達と、情報全体の消失を区別する。表現不能や未確定を母数から除外して改善率を作らない。
6. 両版の技術完了・独立意味判定がそろったpairだけcomparablePairsへ数える。片方だけ完了したpairはpartialPairとして保持し比較成功へ数えない。補完の再送・別path再試行をしない。
7. 途中stopなら未送信の後半問題は未評価。baselineCompleted/candidateCompleted/comparablePairs/plannedPairsを別表示し、完了prefixから全12問の優位性や改善率を外挿しない。

最終statusはgenerationComplete（24技術完了）、allReviewsComplete、candidateAllMatched、baselineMismatchCount、comparablePairs、finalDecisionを別にする。全24armを採点できてもcandidateが不適合なら採用成功ではない。全12candidateが適合しても開発用小標本の結果であり、releaseAccepted=false・人間gold pendingを維持する。

## 永続化・再開・秘密

新journal/live/review/artifactと、new request/response、2データfile、secret guard、question-units/v4 validator/semantic ledger/v2及び親requestの全依存closureをsource hashへ固定する。schema/指示/質問/順序/上限を含むmanifestを凍結し、旧runのsourceやjournalを編集しない。

canonical新directory、0700/0600、共通排他lock、O_EXCL、file→directory→journal fsync、hashchain、正常checkpoint以外の再開禁止を維持。reservedをdurableにしてから固定bodyを送る。技術失敗/保存不明/stop/途中pairではlock保持。raw response/prompt/key/実学習内容を保存しない。秘密guardをrequest/rawresponse/最終parser保存対象へ適用する。

全先行stageの元reviewをlive自身が予約前に再評価する。各artifactはordinal/pairIndex/variant/requestHash/questionHash/planHash/oracleHash/reviewHashとstage/checkpoint/manifest/run bindingを持つ。中立packet IDとjob mappingのhashも固定し、同じ質問だからと版違いのreviewを使い回さない。元review/packet/artifactなし・改変・別stage・arm不足/重複は送信0。stage artifactを固定名へ1度だけ書き、孤立artifactは上書き/自動再登録しない。

レビュー提出wrapperは必ず`{packetId, packetHash, review}`を含める。packetId/packetHashを受領した時点で凍結mappingのordinal/pairIndex/variant/requestHash/responseHashへ照合し、採点後に単にvariantを付け足す方式を禁止する。packetは中立ID・質問・検証済みplan/provenance・oracleを持ち、hashはそのcanonical内容（ID含む）に対して計算する。版名/指示はreviewerへ提示するpacketへ含めない。

stage完了後のpacket準備は共通lock下で、固定stage名のcollection（packetとmappingの両方、最大2MiB）をO_EXCL作成し、file→directory→journalの順に同期して`packets_ready`を記録する。recordはcollectionHash/mappingHash/stage/run/checkpoint bindingを持つ。packet準備完了は比較continueではない。collectionだけ残る不確実状態は上書き/再作成せず監査停止。live自身が全先行collectionを同一fdで再読込し、completedからpacket内容とmappingを照合する。reviewerへは中立packetだけをexportするが、同じOS userがsource/collectionを読めるため厳密盲検や本人認証を保証しない。

両版が同一planなら、question/plan/oracle hashやraw reviewの判定内容・reviewHashが一致すること自体は正常である。reviewHashを別々にすることを要求せず、中立packet ID/hashと外側のarm/job bindingで対象の取り違えを検出する。個別に採点した事実はworkflow上の実監査で確認する。

replayは保存planを固定index/variantから再検証し、保存provenanceを再生成する。技術結果と比較継続判定を元reviewから再計算し、保存したcontinue文字列やsummaryだけを信用しない。artifact hashとreviewerRoleは本人性/独立性を証明しないため、実監査成果物をtrusted callerが確認する。

## 実装順・検証・rollback

1. 今回のoffline response bindingとmockを確認する。
2. 新24job manifest/journal/replay・partial pair状態を通信なしで実装する。
3. 中立review packet/mappingとpaired review artifact、独立採点後のcontinue/stop再計算を実装する。
4. 固定transport・3箇所secret guard・deadline/固定診断を接続し、[比較回帰matrix](RAG_SUBJECT_ROLE_PAIRED_TEST_MATRIX.md)と全Workerを実行する。
5. 独立code/安全レビューでHigh/Mediumなし、実行前料金/新directory/source確認後だけ最初の1pairを実評価する。

今回paid比較のrunner/journalは未実装、API/キー読取0。新moduleを使用しなければrollbackでき、本番/DB/migrationへ影響しない。旧5runは解除・再開せず、未使用20問も保持する。Projectの資料の更新: なし。

独立設計確認の反映：PlannerのMedium（同一plan時のreview提出arm binding）を受け、packetId/packetHashを提出wrapperへ必須化し、採点後のvariant付与だけでは許可しないことを明記した。比較継続条件と技術失敗停止は別で、旧runへ流用しない。安全レビューのdispatch context固定・計数再計算・24/stage上限を実装受入条件として保持する。

最終独立Planner/安全確認：packet提出wrapperとcollectionの補強後、設計上のHigh/Medium残件なし。paid runner/journal実装の安全性確認は今後のmock/独立レビューで行う。packets_readyだけで比較continueしない回帰をmatrixへ追加した。
