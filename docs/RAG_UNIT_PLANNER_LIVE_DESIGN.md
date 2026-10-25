# Unit TaskPlan v4：有限API評価の設計

2026-10-15。High（費用・送信制御・秘密/保存境界）。本書は設計であり実行承認の追加要求ではない。既に承認された継続開発の範囲で実装・mock・独立レビューを進め、全gate通過後だけ有限評価する。今回はコード変更/キー読取/API送信0。

## 目的と固定範囲

[v4入出力](RAG_UNIT_PLANNER_IO_REPORT.md)が実Lunaで受理・完了するか、質問から必要な回答項目を適切に抽出できるかを確かめる。検索/生成回答/日本語OCR/100ページPDF/iPadの総合品質とは別評価である。本番はv1を維持する。

新規unit-task-planner-journal/live/reviewのみを追加する。旧v2/v3のソース・manifest・4失敗run・lock・v3 journalを変更しない。新contractVersion=4、別suiteId、実装レビュー後に固定する新canonical directoryを使う。旧run失敗の再送や旧比較の補完とは扱わない。

固定の別開発8問をindex0..7で各1回、順序固定。unit-task-planner-request/responseの設定（Luna、medium、default、store:false、stream:false、max_output8192）をそのまま使用する。任意question/model/body/variant/追加header/selectorを受け付けない。APIへ渡すのは質問/hash/unit(id,text)だけ。oracle・review・期待task・offsetを渡さない。未使用20問を調整に使わない。

## 段階・予算・時間

| 項目 | 固定上限 |
| --- | --- |
| 送信段階 | 1 + 3 + 4（checkpoint 1 / 4 / 8） |
| 1入口の動作 | 現段階のみ。次段階は独立review後に別呼出 |
| 1送信予約 | 8,192 microUSD（0.008192 USD） |
| 段階予約 | 8,192 / 24,576 / 32,768 microUSD |
| 全8送信予約 | 65,536 microUSD（0.065536 USD） |
| request / response / plan | 32KiB / 256KiB / 32KiB |
| 1送信 / 各段階 | 60秒 / 60・180・240秒 |
| journal / review JSON / stage artifact | 1MiB / 256KiB（各case）/ 2MiB（各stage） |

予約は実請求ではない。2026-10-15に[公式Lunaページ](https://developers.openai.com/api/docs/models/gpt-6-luna)を確認し、通常input 0.10、cached 0.01、cache write 0.125、output 0.50 USD/100万token。input32768を高いcache write率で見積もり4096microUSD、output8192で4096microUSD、計8192を予約する。入力token32768は評価上の保守仮定でありrequest byte制限だけから厳密に保証するものではない。固定body最大7197bytesとusage上限を確認するが、将来の料金やschema計算変更を自動で吸収しない。正式な請求上限・アカウント全体の支出制御ではない。実行直前に料金と地域加算等の適用条件を再確認し、仮定が成立しなければ送信せず設計へ戻る。失敗usage/総実費不明を0へ変換しない。

旧24KiB runnerへ接続しない。新manifestと実body双方で32KiBを検証する。timeoutMs/totalMsをmock目的で許す場合も短縮のみ、各stage cap超過を拒否する。header/body/parse/再検証/保存前後を同一deadlineで監視する。onProgress例外を含む中断後に自動再送しない。

## manifestとjournal

1. 固定manifestにはsuite/contract version、8jobのindex/stage/requestHash/questionHash、入力manifest全体、全size/time/budget上限、全関連source hashを含める。新journal/live/review、v4request/response、question-units、v4validator、親paired/task request、固定fixture/draft、依存v2検証を固定する。意味gateに使うsemantic-review moduleとoracle JSONのhashも固定するが、送信bodyへ入れない。
2. 排他的mkdir、canonical path/owner、directory0700/file0600、symlink/hardlink/inode、running.lock、hashchain、全write/fsync（file/directory）を確認する。部分書込/close/同期/解除失敗は監査停止。lock再作成はbest effortでありOS障害下の完全保証ではない。不明dirは再利用不可。
3. reservedをdurableに記録した後だけdispatchする。stage_finishedとreviewを区別し、pending review/全生成完了では送信0。stopped、reserved未完了、lock残存、tail欠損、manifest/source/job不一致は再開不可。正常checkpoint以外からの再開を拒否する。
4. completedはv4 parserのindex/contractVersion/questionHash/plan/structuralProvenance/model/usage/requestHash/responseHash/semanticCompleteness/evidenceSupport/releaseAcceptedとelapsedをprivate journalへ記録する。固定合成質問由来のplan/provenanceだけを扱い、rawresponse/prompt/key/実学習内容は保存しない。
5. replayは保存planをJSONへ戻して固定indexの質問からv4 validatorとunit生成を再実行し、保存provenanceと完全一致を確認する。保存provenanceやunit一覧を検証入力として信じない。model/usageは同じresponse parserの合成envelopeで再検証し、plan・question・request bindingも照合する。responseHashは元responseの識別であり、再構成envelope hashとの一致を要求しない。上流送信や保存前の真実性は証明しない。
6. 正常stage終了/正常checkpointだけclose後lock解除を許す。初失敗はfailedを記録して後続停止しlock保持する。保存が始まった後の不確実な失敗へfailedを二重appendしない。別pathを作って同じ失敗入力を自動再試行しない。

## 独立意味review gate

生成完了と意味監査完了を分ける。各stage終了後、別の通信なしreview入口で、直前stageに属する全completedを独立確認する。

- [8観点review規約](RAG_UNIT_PLAN_SEMANTIC_REVIEW.md)と凍結8問/13要求oracleを使用する。taskと要求を一対一で対応させ、独立値の結合、誤対象/属性/条件、比較方法と実比較の混同、意味のない過分割、架空labelを確認する。unit参照の形式合格だけでcontinueしない。
- 提出reviewは各caseのquestion/plan/oracle hashにbindし、scopeの妥当な言い換えを独立判断する。oracleの代表spanとの不一致だけで意味誤りにしない。人間によるoracle確認はpendingのまま。
- 各caseが全要求representableかつsemanticStatus=reviewed_match、reviewComplete=true、missing/extra上下限0の場合のみcontinue候補。pending/unsupported/uncertain/対応不可能/形式失敗ではstopする。分からないものをpassへ置換しない。
- review入口は対象stageの全caseを評価し、case集合不足・余分・重複・別stage混入を拒否する。review JSONは256KiB/件以内、hash/長さ/IDを検証する。本文コメントを受け付けない。
- journal reviewにstage/completed/checkpointHash/manifestHash/runId/reviewerRole/artifactHash/decisionと、全対象caseのindex/questionHash/planHash/oracleHash/reviewHash/semanticStatusを結び付ける。reviewHashは提出review JSONをobject key正規化（array順保持）して計算する。成果物の実在・正しい独立監査は信頼する呼出元が確認する。role/hashだけで本人性・独立性は保証しない。
- review JSONと判定結果はprivateな監査artifactに保持し、stage recordへ全件のbindingとそのartifactHashを記録する。review入口とlive入口自身が、予約前に全ての先行承認stageのartifactを再読込して元reviewの全caseを再評価し、集計結果・hash・対象stageとの一致を検査する。最新stageだけを確認せず、過去stageの削除/改変/不明状態も後続送信0で拒否する。live入口がreview_passed文字列だけで次へ進む経路を作らない。
- review artifactもcanonical/private（file0600/owner/inode/link確認、stageごとの固定名・最大2MiB、最大3ファイル）/サイズ上限/改変検知の対象で、元reviewが保持されない場合は監査不能として後続送信0。artifact filename/run directoryは実装で固定し、任意ファイル読取の入口を作らない。artifactはstage固定名へO_EXCLで一度だけ作成し、上書きしない。live/reviewと共通の排他lockをartifact作成・検証からjournal登録まで保持し、file fsync→directory fsync→journal review fsyncの順とする。artifactだけ残った途中状態は自動上書き/再登録せず監査停止し、成功扱いにしない。再読込はsymlinkを辿らないfdを一度開き、同一fdのfstatでtype/owner/mode/nlink/dev/inode/サイズを確認してbyte上限付きで読み、読取後もfdと固定pathの同一性・サイズを検証する。hashと再評価はそのfdで検証した同じbyte列に対して行い、pathの二度読みに分離しない。同一OSユーザー/プロセスによる悪意ある同時書換えへの認証境界を提供するものではない。
- stopは終端。最終stageも独立reviewを必須にし、generationCompleteとsemanticAuditCompleteを別表示する。全件reviewed_matchでも小標本/開発問限定の結果であり、汎用精度・本番採用の合格ではない。

## 通信・秘密・診断

送信URLは固定HTTPS Responses POST、redirect:error。実行入口だけが既存key loaderを使い、module import/manifest/replay/review/mockは鍵を読まない。bodyへのkey混入・responseのkey反射を検出して停止する。raw文字列だけでなく、JSON復号後の保存対象plan/provenanceを含む全string値についてもkeyの混入を検査し、Unicode escape等で隠された反射を保存前に拒否する。検査対象の本文/keyはログや例外へ出さない。Content-Type/UTF8 fatal/累積byte/deadlineを検証し、不正・超過・停止時はbodycancelする。再試行・別model・別key・account切替を行わない。

failedにはphase(fetch/body/validation)、HTTPstatus(nullまたは100..599)、有限allowlist reasonだけを記録する。v4 parserのshape/question_mismatch/references/label/duplicate_role/invalid_task/status_conflict等を固定コードとして保持する。上流message/cause/本文/label/offset/promptは保存・共有しない。各reasonで分かる範囲だけを説明し、taskIndex/fieldを特定できない場合は不明と明記する。診断目的のraw response保持や失敗の再送は加えない。

実行後の共有報告はstage/index/件数/予約/既知完了usage由来の推計/時間/固定reason/意味監査状態/hashだけ。plan/provenance/review全文はNotionや共有RESULTSへ転記しない。

## 検証・ロールバック・次の実装単位

[RAG_UNIT_PLANNER_LIVE_TEST_MATRIX.md](RAG_UNIT_PLANNER_LIVE_TEST_MATRIX.md)の回帰をmockで確認する。Planner/Code Reviewer/Security ReviewerでHigh/Mediumが残ればAPIへ進まない。初実行直前に固定dir・料金・全source/manifest・旧lock保持を再確認する。既存失敗runを解除・再開しない。

実装順は (1) 新journal/replay・v4再検証、(2) review artifact/bindingと送信なしgate、(3) bounded transport/固定診断、(4) 対象/全Worker/独立codeと安全レビュー、(5) 新runのstage0、(6) 実成果物に基づく独立review後だけ後続stage。各単位のmock結果を実モデル精度と区別する。

新評価moduleを使用停止すればロールバックできる。本番API/DB/migration/feature flagに影響しない。今回の完了条件は設計・テストmatrix・独立設計/安全レビューであり、実装/実行完了ではない。Projectの資料の更新: なし。

## 独立設計レビューの反映

PlannerのMedium（live入口が直前review記録のみを信用し得る曖昧さ）を修正し、全先行承認stageをlive自身が予約前に再評価する義務と、同一fdのbyte列によるartifact検証を明記した。安全レビューの排他lock共通化・artifact一度作成/確定順・孤立artifact停止・JSON復号後の秘密反射拒否・各stage最大2MiB（最大3ファイル）の上限を反映した。Planner/安全の最終読み取り確認でHigh/Medium残件なし。Lowの上限表現も各stage2MiB/最大3ファイルへ統一した。今回は実装安全性/モデル品質の合格ではない。
