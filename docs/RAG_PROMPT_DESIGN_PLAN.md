# 汎用RAGのプロンプト設計・評価計画

2026-10-14作成。作成時は計画のみ、実装・本番・API送信は変更していない。対象はrag-wip。点灯時間に限る条件判定から、学習資料の多様な質問へ広げる。独立設計レビューを反映し、段階ごとの確認後に次へ進む。

実施状況（同日追記）: 第0段階の固定policy/context/rubricとoffline比較基盤、第1段階の全規則対応表・意味を変えない責務分離を実装。[棚卸しと検証記録](RAG_PROMPT_POLICY_INVENTORY.md)を参照。生成文字列は旧版と同一。重複文の統合・partial指示の意味修正・新版の実API回答比較は未実施で、第1段階全体は未完了。

続行結果: [重複整理A/partial精密化Cの比較](RAG_POLICY_REVISION_REPORT.md)を実施。固定3問×2style×旧版/A/A+C/C単独の24実回答で、候補のsource_only回答に必要差分の欠落が残り、A/Cとも採用見送り。現行prompt出力はv1と完全一致へ復帰。候補と全結果は評価専用に保存。次は同じ質問への指示追加を繰り返さず、質問要求項目を整理する第2段階の設計と回答漏れ評価を見直す。第1段階全体や汎用RAGが完成したという意味ではない。

要求項目の設計に着手: [回答要求項目と漏れ評価](RAG_ANSWER_REQUIREMENTS_DESIGN.md)。開発30問の評価専用台帳、reviewのquote/scan形式、限定差分probe、前回回答のoffline分析を実装。新しい本番の質問解析器/自動修正器ではなく、手書きoracleと独立reviewの土台。runtimeのv1生成文字列を維持し、追加API送信なし。第2段階全体は未完了。

## 目標と現状

資料の記載を正しく読み、質問に必要な説明を過不足なく返す。source_onlyは資料確認、explainは区別した必要な背景説明を許可する。資料固有の値・式・条件を一般知識で補わない。単なる「答えない」増加を精度向上と評価しない。

検索・基本回答は共通だが、サーバー側の比較構造化は点灯時間/価格/明るさ/温度の限定書式。共通promptには局所修正が積み重なり、生成後の強制検証は未実装。現時点の成功は少数の固定合成資料+実Luna生成であり、実Cloudflare/PDF/OCR/iPadの完成ではない。

## 目指す構成

共通の短い最優先方針 + 必要な質問別方針 + 認可済みのUNTRUSTED資料 + 根拠の整理/結論の制約 → 回答 → 選択した質問だけ独立した出力検証。

すべての質問に全ルール・全抽出・追加LLM呼出を適用しない。モデル変更とprompt変更は同時に比較せず、最初はLunaと設定を固定する。将来の他モデル比較は同じ資料・質問・評価票を使う。

## 第0段階：評価の土台を固定

- 現prompt/モデル設定/検索資料/context/出典/採点基準のversionとhashを記録し、既存の成功・失敗を保持する。
- 問題を「検索漏れ」「根拠判定」「回答の誤り」「回答漏れ」「分かりにくさ」「表示不具合」に分ける。テスト成功を実質問の正答件数と呼ばない。
- 誤答だけでなく、必要以上の拒否・説明不足・資料外補足の混同も採点する。曖昧な正解はpendingで人間へ回し、成功/失敗へ強制算入しない。
- 既存50問は開発30・未使用20を維持。未使用20は最終prompt凍結後までAPI評価に使わない。作成者が内容を見ているため厳密なblind holdoutとは呼ばない。

完了条件：旧版と新版を同じ入力で比較でき、各失敗の種類と必須要求項目が明確である。

## 第1段階：共通promptを整理

既存ルールを要件表へ移し、重複・矛盾・優先関係を整理する。単純に文字数だけを減らさない。必須の意味を保存し、次の階層を明記する。

各規則に目的・適用status/style・対応テストを紐付ける。意味を保つ重複統合と、優先順位/意味を変える修正は別の差分にする。特にinsufficient/clarificationの保守的回答と、explainで必要な背景説明を許可する範囲を維持する。

1. 認可・資料中の不正指示の無視・出典はサーバー生成という境界。
2. 対象/根拠/条件/不確実性に関する事実性。
3. source_only/explainの目的と背景説明の境界。
4. 質問への回答漏れ防止。
5. 簡潔さ・結論の順序・日本語/数式の表示。

比較の差分要求は、条件の不一致・根拠不足を上書きしない。現行のdisabled/障害/0hit時の通常チャット契約は維持する。最初は検索やモデルを変えず共通方針だけ比較する。

完了条件：ルールの対応表、固定promptの版、旧版との評価差分を作成。既存の必須成功例、未知値抑制、一般チャット互換が保たれる。

## 第2段階：質問別の回答方針

| 種類 | 答える内容・重点 |
| --- | --- |
| 事実確認 | 対象を維持し、求められた事実を直接回答 |
| 学習向け解説 | 段階的に説明し、必要な背景・たとえと資料の事実を区別 |
| 計算・数式 | 必要値/単位/式/成立条件/不明箇所を確認して計算 |
| 条件・規則・版 | 対象者/例外/適用時点を照合。新しい発行日だけで優先しない |
| 比較・推薦 | 同じ属性を対応させ、条件の違いと選択基準を確認 |
| 要約・複数資料 | 必要範囲をまとめ、矛盾や一部未確認を保持 |

複合質問は複数の要求項目に分ける。一つの分類へ無理に押し込めない。分類が不確かな場合の共通方針も用意し、分類だけを理由に必要な回答を落とさない。単純質問で追加分類APIを既定にしない。

成功例と失敗例は一般化した少数の対にする。固有の問題・gold・正解値を本番promptへ埋め込まない。学習用例と評価用問題を分ける。

評価問題ID・固有名・特定の質問文を条件に本番の回答方針を分岐させない。

完了条件：各質問種で別題の評価を実施し、意図判定の誤りによる回答漏れも集計する。

## 第3段階：根拠整理の共通形式と適用判断

共通形式を対象・属性・値/型・原単位・条件・適用期間/時点・根拠引用/offset/出典にする。数値以外のカテゴリ、範囲、上限/下限、仮定、訂正、否定も区別し、全てを単一の確定数値へ変換しない。

形式の例は実験の温度/試験方法、料金の対象者/期間、製品の環境/測定条件。分野の名詞ごとに例外を増やすのではなく、共通データと条件型別の判定を分ける。狭い既存parserを「汎用化済み」と改名しない。

- 必要条件が何かと、資料で何を確認できたかを分ける。条件が書かれていないことを同一条件の証明にしない。
- 「資料にない」「parserが未対応」「資料同士が矛盾」「その主張に条件確認が不要」を区別する。条件不明を理由に、根拠のある数値提示まで一律に拒否しない。
- 記載値の算術差、同条件の性能優位、総合的なおすすめを別の結論として扱う。
- 計算指標は分子/分母/意味を明記する。計算できることだけで使用費用や総合価値を保証しない。
- 抽出候補は未信頼データとし、原文一致・対象との対応・範囲を検証する。原文一致だけでは意味的な正しさは保証できない。
- 規則で扱える形式は決定的に処理する。自由文に追加LLM抽出を使うかは、対象率/誤り/費用/待ち時間を測って別判断する。
- 認識範囲外/矛盾/欠落を明示し、元の資料を保持する。範囲外を黙って同条件や根拠なしへ読み替えない。

完了条件：点灯時間以外の実験・料金規則・製品条件・非数値属性で成功/負例を確認。必要な回答を過度に拒否しない。分だけの点灯時間等、既存の上流根拠判定の未対応も別に修正する。

## 第4段階：回答の生成後検証を設計・試行

現在の回答前self-checkとは別の工程とする。最初は評価環境で生成回答を検証し、見逃しと誤拒否を測る。特に比較・計算・適用条件の質問を対象に、主張と根拠の対応、条件を超えた結論、回答漏れ、補足の境界を確認する。

本番に入れる場合の初期案は、対象リクエストだけ回答をbufferして検証後に送る。未検証の文章を先にstreamして後から注意書きで修正しない。最初は生成1回+検証1回まで、失敗時に自動再生成を繰り返さず保守的な応答とする。検証不能を合格扱いしない。

検索0件/検索障害時の既存通常チャットfallbackは維持する。一方、取得根拠を使う回答がvalidatorで不合格になった場合は、同じ危険な比較を通常チャットで再生成するfallbackにしない。

deadline、最大bytes/tokens、API予算、stream待ち時間、キャンセル、返金/二重課金防止、再認可を先に設計する。資料失効時は検証用送信/公開も止める。自動修復を将来導入するなら再検証分も含む呼数/費用を別に決める。

LLM検証器も誤るため「完全に防ぐ」とは主張しない。別モデルの利用も独立性/品質/費用を評価して決め、最初から高額モデルを全質問へ追加しない。

完了条件：検証器の見逃し/誤拒否・待ち時間・費用を独立評価し、streaming/認可/課金のレビューを通す。採用前はruntime validator未実装という状態を維持する。

## 第5段階：固定評価と公開判断

順序は、対象箇所の少数確認→同じ能力の別問題→開発30問の両style→prompt/設定凍結→未使用20問の両style→実Cloudflare/日本語OCR/代表100ページPDF/iPadとする。既知失敗の修正効果と別問題への一般化を分ける。未使用問題で調整した場合、その問題を以後holdoutと呼ばない。

検索は正解ページ/chunkの取得率、回答は要求項目の正確性/漏れ/条件/単位/背景境界/分かりやすさを別々に記録する。source_onlyとexplainを別集計。重大失敗は平均点で相殺しない。複数回の再現性、p50/p95待ち時間、入力/出力token、外部費用も測る。

初期受入案は、固定評価内で捏造・対象混同・条件無視の断定・不正指示への追従0件、既存の必須成功ケース維持。要求項目の達成率95%以上は目標案であり実績ではない。人間のgold/説明品質確認前やpendingを含む成績だけで公開しない。少数で0件でも母集団の失敗率0を保証しない。

安全性の全確認、主要分類の未達解消、実検索/実機がそろってから段階有効化を別依頼で扱う。計画の作成はdeploy承認ではない。

## 実施順と今回の次の一手

まず第0〜1段階だけを実装単位にし、既存ルールの対応表と共通promptの整理案を作る。レビューと同一入力比較を終えてから質問別方針、共通根拠形式、生成後検証へ進む。同じ問題への小修正を無制限に繰り返さず、段階の受入条件で進退を判断する。日程/本番日を未検証のまま確約しない。

認証・同意・accountKey分離・Locked除外・構造化出典・削除・通常チャット互換・本文非ログを全段階で維持する。API/返却形式は旧アプリ互換を保つ。秘密・実ノートはfixtureやログへ入れない。

## 参考と変更範囲

- [LlamaIndex default prompts](https://github.com/run-llama/llama_index/blob/main/llama-index-core/llama_index/core/prompts/default_prompts.py)：context/質問/回答の役割分離。
- [RAGFlow citation prompt](https://raw.githubusercontent.com/infiniflow/ragflow/main/rag/prompts/citation_prompt.md)：主張ごとの根拠対応と例示。引用IDをLLM生成する方式はStudiquoへ移植しない。
- [LangGraph Self-RAG旧公式例](https://github.com/langchain-ai/langgraph/blob/main/examples/rag/langgraph_self_rag.ipynb)：生成と根拠/有用性の検証の分離。当該例はarchiveであり現在の製品品質保証ではない。

今回の変更は本計画とNotion記録のみ。既存コード/fixture/gold/flags/DB/secret/複製ファイルは変更せず、API呼出・deployなし。検証は計画と現状の照合・独立レビュー・差分確認で行い、コードテストは再実行しない。採用済み実装の構成は変えていないため、Projectの資料の更新: なし（将来の設計確定/実装時に再判断）。

独立Plannerレビュー済み。意味変更と短文化の分離、範囲/近似/仮定/未対応の区別、生成後検証の送信前buffer/再認可/失敗時の扱いを反映した。公開判断の数値は提案段階で、既達成値ではない。


## 2026-10-15 評価用要求分解の進捗

回答漏れの台帳に続き、別分野6問の操作候補初版を凍結。分類規約の曖昧さと固有名の誤検出を残して本番へ接続しない。[TaskPlan v2契約](RAG_TASK_PLAN_V2_CONTRACT.md)で操作/属性/対象/状況と根拠支持を分離し、別oracle/validatorを整備。[質問のみのplanner入力](RAG_TASK_PLANNER_REQUEST_REPORT.md)は固定6問のオフラインrequest生成まで。gold非送信・元schema保持を独立確認。モデル抽出、API schema受理、意味完全性、人間goldは未確認。次は予算journal付きJSON応答adapterの安全確認と限定Luna評価。runtime v1/未使用20問を保持し、第2段階完了や回答品質改善とは扱わない。


2026-10-15続き: [有限API評価](RAG_TASK_PLANNER_LIVE_DESIGN.md)を独立設計/コード/安全レビュー後に実施。固定6送信/6完了、形式/UTF16整合を確認。独立意味評価で独立値要求の結合と条件role未達が残り本番採用保留。厳密span一致0は意味精度0%と同義ではない。初回結果を固定し、次は別開発問題と過分割負例で一般規約候補を検証する。追加APIの即時反復を止め、runtime v1/未使用20問を維持。


2026-10-15新8問の比較準備: 代表13scopeの独立注釈確認と元案/候補16body、質問別response bindingをオフライン検証（Worker1361成功）。候補のモデル品質は未評価。次は[対の評価設計](RAG_TASK_PLAN_PAIRED_DESIGN.md)の同一ledger・6+6+4有限比較をHigh単位として実装/安全レビューする。旧6問の結果と本番v1を維持。


2026-10-15有限比較の実行: 制御実装と安全gate後の最初の送信試行で停止し、比較結果は未取得。本文なし診断を追加し全Worker1374成功。原因/usage/費用は旧generic記録から特定不能。旧runとsourceを保持し自動再送なし。[報告](RAG_PAIRED_PLANNER_LIVE_REPORT.md)の診断版第1段階だけの再評価案はユーザー判断待ち。本番v1/旧6結果/未使用20問を保持。


2026-10-15診断版stage0: ユーザー指示後の限定再評価はbaseline1件成功/candidate1件v2検証拒否で停止。HTTP200まで確認、個別違反は未特定。候補効果は未評価で追加APIなし。次は本文なしの違反分類をoffline整備する。詳しくはRAG_PAIRED_PLANNER_LIVE_REPORT.md。


## 2026-10-15 原文引用から位置を決める評価用v3候補

subjectの引用位置不一致を受け、[v3設計](RAG_QUOTED_PLAN_V3_DESIGN.md)とpure schema/resolverを評価専用に追加した。モデルは数値offsetでなくtextと直前/直後の引用を返し、serverは完全一致する場所が一つの場合だけ位置に変換する。複数/無一致/Unicode不正/余剰fieldは固定エラーにし、推測・fuzzy・正規化・v2失敗の救済をしない。元v2 validatorによる最終検証を維持する。

独立設計/コードレビュー完了。Medium（敵対的例外Proxyのinstanceofから任意errorが漏れる経路）をWeakMap内部エラー識別に修正し、再レビューで未解決High/Mediumなし。専用13テストと、既存開発8問13scopeのoracle位置へのround-tripを確認。ただしモデル抽出の成功率/回答精度は未評価。今回追加API/キー読取0、3つの失敗runのlock/旧v2/本番v1/未使用20問不変。

次はこのv3専用の質問だけを渡すrequest/response bindingをオフラインで整備する。元のpaired request/parser/runnerへ黙って差し替えず、新contract versionで分離する。API評価はその後の有限予算/manifest/独立安全確認の単位として扱い、既存失敗runの解除・再送をしない。全Worker結果はv3設計書の最終記録を参照。Projectの資料の更新: なし。


2026-10-15 v3入出力: [専用report](RAG_QUOTED_PLANNER_IO_REPORT.md)の固定8問request/response bindingをoffline追加。既知段落置換のみ、分解規約/質問/モデル設定不変、v3引用/前後文schemaと独立resolverを使用。対象9/全Worker1402/独立9成功、未解決High/Mediumなし。旧sourcehash/3runlock保持、API/キー読取0。本番v1/未使用20問保持。次は新contract専用有限runのHigh設計と安全確認。実モデル/schema受理/費用/意味品質は未評価。Projectの資料の更新: なし。


2026-10-15 v3有限runの設計：[RAG_QUOTED_PLANNER_LIVE_DESIGN.md](RAG_QUOTED_PLANNER_LIVE_DESIGN.md)を独立Planner/安全レビューして具体化。固定8問/1+3+4、予約8192/24576/32768microUSD（合計65536、実費ではない）。正常checkpointだけでは進まず、独立監査のcontinueとcheckpoint/manifest/source/request/run bindingをdurableに記録して次stageを許可する。scope欠落/結合/対象誤対応/条件role未達はstop、妥当な別spanは注釈差。replayはquotedPlanから再解決して保存resolved planとの完全一致を確認する。全関連sourceを固定し、旧3runを再利用しない。実行直前に料金を確認する。
今回は設計文書だけ、API/キー読取/コード変更0。直近全Worker1402成功はv3IO実装時の結果で、今回再実行していない。次はこの設計のrunner/送信なしreview入口/mockを実装し、独立コード・安全レビュー後だけ実APIへ進む。未解決High/Medium設計指摘なし、実装/実品質は未確認。利用枠通常可（5時間90%使用）を確認、上限回避操作なし。Projectの資料の更新: なし。


2026-10-15復帰後：通常枠回復/並行作業なしを確認し、[通信なしjournal基盤](RAG_QUOTED_PLANNER_JOURNAL_REPORT.md)を実装。manifest/private ledger/replay/1+3+4監査gate、quotedPlan再解決、strict比較、保存snapshotを追加。対象12/全Worker1414成功、独立安全最終12成功、コード最終確認は結果JSONを参照。review gateは信頼した呼出元が実artifactを確認して登録する方式で、本人性/独立性を認証しない。transportAttached:false、API/キー読取0、旧sourcehash/3runlock保持、本番v1/未使用20問不変。次はbounded transport、phase/status/固定reason、deadline/bytes/secret guardの統合と全回帰/独立コード安全gate。現在基盤のjournalを実APIrunへ転用せず、transport sourceを含め新manifestを固定する。Projectの資料の更新: なし。


2026-10-15 v3 transport統合と実評価：[RAG_QUOTED_PLANNER_LIVE_REPORT.md](RAG_QUOTED_PLANNER_LIVE_REPORT.md)。旧offline journal source/testをbaselinesへ保持し、新manifestv2/live+review hashを固定。transport11/journal12/全Worker1425成功、独立code/安全各22成功。公式Luna料金を確認して新固定run `/private/tmp/studiquo-rag-quoted-v3-20261015-01` を1+3で評価。第1段階1成功・独立意味監査continueの実artifactをhash登録後、第2段階は2成功してindex3でHTTP200/validation/quoted_task_planner_quote_not_found。4試行/3完了/1失敗・後続4未送信・lock保持。引用text/prefix/suffixのどこが不一致かはpayload非保存で不明。初失敗停止で終了し再送しない。
独立最終監査でchain/source/job/artifact hashと成功3問の要求分割・対象属性対応を確認。厳密注釈差は意味誤りとせず、3完了を汎用精度へ一般化しない。予約32768microUSD、既知完了usage試算0.00089974USDだけ分かり、失敗usage/総実費は不明。旧3runもlock保持、本番v1/未使用20問不変。次は追加APIなしで引用/context契約の負担と代替表現をオフライン検討し、現runの再開/lock解除/別path自動再送をしない。個別fieldの特定ができたと主張しない。Projectの資料の更新: なし。


2026-10-15 v3失敗後のoffline検討：[RAG_QUESTION_UNIT_PLAN_DESIGN.md](RAG_QUESTION_UNIT_PLAN_DESIGN.md)。既存A厳密引用を基準として凍結保持し、B fuzzy/正規化救済は不採用。C質問unit ID+role別解釈ラベルの別v4契約を設計し、独立Plannerレビューで未解決High/Mediumなし。原文lossless復元・questionHash binding・既知ID/型上限の形式検証と、ラベル/role/要求分割の意味評価を分離する。正しいIDで架空ラベルや全role同参照が形式合格し得る負例を残し、ID coverageを意味recallとしない。各role参照数/byte上限での表現不能も別集計する。境界規則/Unicode/上限は次のpure preprocessor実装前に固定する小契約として未完了。
今回コード/API/キー読取0、テスト再実行なし。旧4runのsource/journal/lockを保持し、失敗fieldが分かったと主張せず再送もしない。本番v1/未使用20問不変。次はunit境界の最小契約とpure preprocessor/反例をoffline実装し、その後v4 schema/validator/人手oracle意味比較へ進む。モデル品質改善・本番採用は未確認。Projectの資料の更新: なし。


2026-10-15 unit前処理：[RAG_QUESTION_UNITS_CONTRACT.md](RAG_QUESTION_UNITS_CONTRACT.md)の最小境界規則を固定し、pure question-units.mjsを追加。全文入力検証→記号/改行run、空白付着、lossless復元、scalar境界、u1..u64/hashを確認。65unit以上は部分出力なしunsupported。機械的参照で意味分割/grapheme境界は保証しない。専用11/全Worker1436/独立11成功、1000組合せと開発8問の位置保持のみ確認。API/キー読取0、モデル品質未評価、凍結source/4失敗runlock保持、本番v1/未使用20問不変。次はv4 role参照上限と表現不能の小契約を確定し、schema/validator/形式合格の意味誤り負例をoffline準備。既存失敗runの再開/再送なし。Projectの資料の更新: なし。


2026-10-15 v4 schema/validator：[RAG_UNIT_TASK_PLAN_V4_CONTRACT.md](RAG_UNIT_TASK_PLAN_V4_CONTRACT.md)で別評価契約を実装。案のrole参照4上限を既知unit数まで（max64）に拡張し、5unit以上も表現可能にした。task16/subject4/condition4/label256UTF16/plan32KiB等の上限は残る。JSON文字列のみを検証し、質問からunitを再生成してhash/既知ID/形/status/unknownを照合する。原文は共通table一度だけ、展開結果256KiB以内。正しいIDでも架空label/誤role/過剰参照が形式合格し得る負例をpendingとして保持する。
対象14/全Worker1450/独立14成功、High/Mediumなし。API/キー読取0、凍結source/4失敗runlock保持、本番v1/未使用20問不変。次はラベルとrole対応の独立意味評価規約・既存oracleとの一対一照合を準備し、その後v4質問のみrequest/responseへ進む。形式合格/ID coverageを意味精度としない。モデル品質改善は未評価。Projectの資料の更新: なし。


2026-10-15 v4独立意味review集計：[RAG_UNIT_PLAN_SEMANTIC_REVIEW.md](RAG_UNIT_PLAN_SEMANTIC_REVIEW.md)。外部reviewの8観点を受け、承認/可能graphの最大一対一matchingからoracle相対missing/extra上下限を集計する。未reviewを誤り扱いせず、unsupported/uncertainも母数に保持。形式合格と意味合格、提出reviewと本人性保証を区別し、humanReview/releaseは未承認のまま。対象17成功（全81の2×2graph）、全Worker1466成功（追加16まで、最後の総当たり1件は対象のみ）、独立16成功・High/Mediumなし。開発8問/13要求は合成reviewの集計roundtripだけでモデル品質ではない。API/キー読取0、本番v1/未使用20問/旧4runlock保持。Low残件はreview hash出力の追跡性で、元review/artifactは呼出元で保持する。次はoracle/reviewをimportしないv4質問のみrequest/response bindingをoffline実装する。Projectの資料の更新: なし。


2026-10-15 v4質問のみ入出力：[RAG_UNIT_PLANNER_IO_REPORT.md](RAG_UNIT_PLANNER_IO_REPORT.md)。固定開発8問からquestion/hash/server unit(id,text)を送るbodyをoffline生成し、v4版/既知ID/schema、completed/usage/refusal/byte/原文tableを検証する新request/responseを追加。oracle/review/offset/期待taskの送信なし、scope5規則/Luna medium保持、旧v2/v3 source不変、意味pending/releasefalse。対象9/全Worker1476/独立9成功、High/Mediumなし。cloneテストLow修正後対象再実行成功。合成13taskのmockは実モデル精度ではない。API/キー読取0、本番v1/未使用20問/旧4lock/v3journal hash保持。32KiB requestは旧24KiB runner互換ではなくそのまま接続しない。次は別v4有限run設計・予算/段階意味review/初失敗停止/診断privacyの独立安全gateへ進む。Projectの資料の更新: なし。


2026-10-15 v4有限run設計：[RAG_UNIT_PLANNER_LIVE_DESIGN.md](RAG_UNIT_PLANNER_LIVE_DESIGN.md)と24件の[LIVE_TEST_MATRIX](RAG_UNIT_PLANNER_LIVE_TEST_MATRIX.md)を追加。固定8問1+3+4/予約8192microUSD毎回・65536合計（実請求上限ではない）/32KiBbodyを別v4runとして設計。外部8観点reviewの全case reviewed_matchだけcontinue、private artifact保持と全先行stageをlive自身が予約前に再評価、同一fd検証、共通lock/O_EXCL/fsync順/孤立artifact停止、復号後秘密反射拒否を必須化した。独立PlannerのMediumと安全5条件を反映し最終High/Mediumなし。公式Luna料金2026-10-15再確認、実行直前も再確認する。今回設計のみ、コード/テスト実行/API/鍵読取0。文書リンク/24行/diff/旧v3sourcehashを確認。直近全Worker1476成功は前工程の結果。次は新v4journal/replay→review artifact gateをoffline実装し、その後transport/mock/独立code安全gateへ進む。本番v1/未使用20問/旧4runを保持。Projectの資料の更新: なし。


2026-10-15 v4 journal/元review gate：[RAG_UNIT_PLANNER_JOURNAL_REPORT.md](RAG_UNIT_PLANNER_JOURNAL_REPORT.md)。別offline manifest（transportAttached:false）でv4保存plan/provenanceを固定質問から再生成し、独立reviewの元JSONをprivate stage artifactへ保持。共通lock/O_EXCL/file→dir→journal fsync、全先行stageをopen/予約前に同一fdで再評価、孤立/欠損/改変/秘密でない固定reason/unknownを保持。continueは全case reviewed_matchのみ。対象21/全Worker1497/独立code21・安全21成功、High/Mediumなし。API/鍵読取0、旧v3source/journal hashと4runlock保持、本番v1/未使用20問不変。人間oracle確認pendingとモデル意味品質未評価を維持。24matrixのtransport項目を完了したとは扱わない。次はbounded transport（decode後秘密反射・deadline・固定診断）の実装と独立安全gate。新transport manifestを固定しofflineテストrunを転用しない。Projectの資料の更新: なし。


2026-10-15 v4秘密反射pure helper：[RAG_UNIT_PLANNER_SECRET_GUARD_REPORT.md](RAG_UNIT_PLANNER_SECRET_GUARD_REPORT.md)。使用枠95%・並行作業なしを確認し、完結可能な小単位としてraw/JSON1段復号後の全string/property名を検査するguardを追加。256KiB/深さ64/node65536、固定error/戻りundefined、IO/logなし。対象7/全Worker1503（追加6まで・最後の多重JSON1件は対象のみ）/独立コード安全7成功、High/Mediumなし。多重JSONはraw単独で十分でなく、request/rawresponse/最終parser保存対象の3箇所適用を次transportの必須条件にした。今回API/鍵読取0、旧v4offline source/manifest不変、transport/journalへ未接続・保存経路安全性/モデル品質未評価。次はbounded transport/deadline/bodycancel/固定診断/3箇所guardを実装し新manifestで独立gate。上限到達時は切替/reset回避せず次回へ。Projectの資料の更新: なし。


2026-10-15 v4 bounded transport：[RAG_UNIT_PLANNER_LIVE_REPORT.md](RAG_UNIT_PLANNER_LIVE_REPORT.md)。通常枠回復/並行作業なしを確認して新live/live-journal/live-reviewを分離追加。別suite/manifestv2/全16source固定で旧offlineを拒否、1+3+4/予約/全先行review再評価、deadline/bodycancel/固定phase/status/reasonを実装。request/raw response/最終parser保存JSONの3guardでUnicode escape/二重JSON秘密反射をcompleted前に拒否する。対象live15+journal21=36/全Worker1540/独立code36・安全43（guard7含む）成功、High/Mediumなし。旧v3/v4offline source/journal hashと4runlock保持、本番v1/未使用20問不変。今回はAPI/実キー読取0、実run未作成、モデル/schema品質未評価。次は公式料金/仮定/最終source・manifest/新canonical directory未使用をpreflightし、新v4 stage0の1問だけ実評価。独立意味review後だけ後続stage、初失敗停止/別dir自動再送なし。Projectの資料の更新: なし。


2026-10-16 v4実API評価：[RAG_UNIT_PLANNER_API_RUN_REPORT.md](RAG_UNIT_PLANNER_API_RUN_REPORT.md)。公式料金/通常枠/固定manifest/sourceと旧lockを確認して新run `/private/tmp/studiquo-rag-unit-v4-20261016-01` を1+3+4で実行。8送信/8形式完了/通信形式エラー0、独立意味監査7問reviewed_match・index5だけmismatch_detected。条件/例外の2要求はattribute内に残るが明示対象をsubjectsへ出さないrole欠落であり、情報全消失と混同しない。stage0/1実監査continue登録後だけ後続へ、stage2最終stop登録・lock保持。generationComplete=true/finalReviewComplete=false。最終23record/hash `fd486aa7e2a4b3d5015b0a2245584c8553c667ed4557ae9a444a433122abfd2f` を独立安全監査。予約65536microUSD、usage料金推計0.00231765USD（請求不明）、要求抽出中央値4.200秒/最大7.318秒。全8問1unitで複数unit未評価、人間gold pending、7/8を汎用精度としない。本番v1/未使用20問不変、旧4+新stopの計5runを再開/解除/別path自動再送しない。今回コード変更なし・テスト再実行なし（直近全Worker1540成功）。次は [RAG_UNIT_PLANNER_ROLE_FOLLOWUP.md](RAG_UNIT_PLANNER_ROLE_FOLLOWUP.md) の汎用role修正候補と別題/複数unit/対象不在・名詞過抽出の開発oracleを先に固定する。現source/prompt/run凍結、追加APIは別有限設計gate。Projectの資料の更新: なし。


2026-10-16 subjects修正候補：[RAG_SUBJECT_ROLE_CANDIDATE_REPORT.md](RAG_SUBJECT_ROLE_CANDIDATE_REPORT.md)。通常枠/並行作業なしを確認し、先に別開発12問/14要求oracleを独立確認（10multiunit・全7operation・subjects空2）。背景名詞/条件と対象/別対象別属性/対象名中operation語の負例を含む。質問とoracleを分離・hash bindし、人間gold pending維持。その後、旧v4指示そのままbaselineと汎用subject保持4規則だけ追加candidateの固定requestを別moduleへ追加。schema/model設定は同一、24bodyhash/clone/index+variant/32KiBを検証、oracle/reviewのmodel入力なし。対象8/全Worker1548/独立code8成功、oracle注釈High/Mediumなし。API/鍵読取0、精度改善・新schema実受理は未評価、計算operand意味/task bindingも対象外。旧source/prompt/stop journal hash・計5runlock保持、本番v1/未使用20問不変。次は新12問×2variantの応答bindingと別有限比較runの予算/段階review/停止設計。旧8問runnerへそのまま接続せず旧run再送なし。Projectの資料の更新: なし。


2026-10-16 paired応答binding/High設計：[RAG_SUBJECT_ROLE_RESPONSE_REPORT.md](RAG_SUBJECT_ROLE_RESPONSE_REPORT.md)。新parserは固定index/variant/observedRequestHash/rawの4引数で実送信contextを期待bodyhashに照合し、同質問の版違いを復号前に拒否。local bindingは上流実行証明ではない限界も回帰した。対象8/全Worker1556/独立code8成功。別High設計は12pair24送信（偶奇順・stage2/6/8/8、予約196608microUSDで実請求上限ではない）。確定baseline意味不適合のみ比較継続を許し、技術失敗/候補不適合/未知は停止、partial/prefix件数を分離する。Planner指摘の同一plan時arm bindingを提出packetId/hash+固定mappingで補強し、元review/packet collection再検証・packets_readyとcontinue分離を21予定回帰へ記録。最終Planner/安全High/Mediumなし。今回API/鍵0、paid runner未実装、改善精度未評価。旧candidate sourceとstop journal hash/5lock、本番v1/未使用20問保持。次は新24job manifest/journal/replay→中立packet/review gateをoffline実装、旧runへ流用しない。Projectの資料の更新: なし。


2026-10-16 paired台帳のoffline切出し：[RAG_SUBJECT_ROLE_LEDGER_REPORT.md](RAG_SUBJECT_ROLE_LEDGER_REPORT.md)。24job/偶奇順/4段階上限/source closureのmanifestとstage0のみNDJSON replayを追加。transport/persistence/reviewGateAttached=false・maxExecutableStage=0で、まだファイル保存・lock・review受付・送信なし。予約/完了/技術失敗/review待ちを再計算し、片側完了をpartial、比較済みは0のまま、予約/途中pairのreopen不可・stage1/review文字列拒否を検証。独立Medium（0完了でも予約済みpairを未着手へ数える）をreservedPairs/unreservedPairsへ分離修正し、最終コード/安全各12成功・High/Mediumなし。API/鍵0、実モデル品質未評価、旧candidate sourcehash/停止journalhash/5lock保持、本番v1/未使用20問不変。次はprivate file/共通lock/O_EXCL/fsyncの保存wrapper→中立packet/mappingと元review gate→transportを実装。今回のoffline台帳をpaidrunへ転用しない。全Workerの最終結果は専用report/resultsを参照。Projectの資料の更新: なし。


2026-10-16 paired stage0保存：[RAG_SUBJECT_ROLE_JOURNAL_REPORT.md](RAG_SUBJECT_ROLE_JOURNAL_REPORT.md)。旧pure ledgerを無変更でouter persistence manifest+inner ledgerとして保存するwrapperを追加。別offline suite、0700/0600・共通lock/O_EXCL・同一fd有界read・前後stat・全byte/source照合・fsync完了後だけ予約成功。初期/first-pair正常checkpointだけ再開、予約/partial/failed/poisonはlock保持。stage1/review/packet/transportは未接続。対象14回帰にclose故障/読取中差替えを含む。コード/安全の独立確認High/Mediumなし、最終テスト件数はreport/results参照。API/鍵0、旧candidate/ledger sourcehash・停止journalhash/5lock保持、本番v1/未使用20問不変。次は中立packet/mapping・元review artifactと全先行再評価gateをoffline実装し、その後transportを新manifestへ接続する。今回のoffline runをpaidrunへ転用しない。Projectの資料の更新: なし。


2026-10-16 paired中立packet：[RAG_SUBJECT_ROLE_PACKETS_REPORT.md](RAG_SUBJECT_ROLE_PACKETS_REPORT.md)。stage0完了ledgerから中立UUIDの質問/plan/provenance/oracle packetとprivate jobmappingを作成・再検証するread-only helperを追加。提出時のpacketId/hash照合で同plan両版も取り違えを拒否し、同一review内容は許容。意味採点/本人性/秘密非混入/保存/packets_ready/continue未実装で、rawReviewをそのまま保存しない。対象8/独立コード8・安全8成功、High/Mediumなし。全Worker結果は専用report/results参照。次はcollection全体の固定hash/private保存と元review artifactの採点/再評価gateを新manifestへ接続し、別collection差替えを拒否する。旧candidate/ledger/journal sourcehash・停止journalhash/5lock保持、API/鍵0、改善未評価、本番v1/未使用20問不変。今回helperだけでは最初のcollectionの真正性や継続権限を保証しない。Projectの資料の更新: なし。


2026-10-16 review接続の受入条件：[RAG_SUBJECT_ROLE_REVIEW_GATE_ACCEPTANCE.md](RAG_SUBJECT_ROLE_REVIEW_GATE_ACCEPTANCE.md)。通常枠利用可だが5時間97%使用・並行作業なしを確認し、今回は文書のみで完結。固定collection全byte hash→提出packet照合→個別semantic採点→元review保存→全先行再評価の順と、baseline確定不適合のみ継続可/候補不適合・未知・技術失敗停止を具体化。別collection差替え・packets_ready単独・同plan両版・保存故障等の予定回帰を記録。実装/テスト再実行/API/鍵読取0。直近全Worker1590成功は前工程の結果。次回はcollection/private保存とreview artifact/gateを新manifestで実装し、独立コード/安全確認。既存stage0 module/runは拡張・再利用しない。制限到達時は切替/reset回避せず次回へ。Projectの資料の更新: なし。


2026-10-16 stage0元review採点/private gate：[RAG_SUBJECT_ROLE_REVIEW_GATE_REPORT.md](RAG_SUBJECT_ROLE_REVIEW_GATE_REPORT.md)。通常枠回復/並行作業なし確認、受入条件のinode検出範囲Mediumを同一handle/読取前後へ限定して解消。pure artifactは元reviewから各armを8観点採点し、候補適合+全reviewComplete/representable、baseline適合または確定不適合だけ比較continueを再計算。形式不正拒否、未知/unsupported正規stop。別private controlはledger/source閉包、初回collection全bytehash、元reviewartifactをO_EXCL/file→dir→journal同期し、毎操作/再openで全再採点する。stage1Authorized/transport/releaseはfalse。対象artifact9+control16=25成功、最終独立コード25・安全23（最後の2回帰はコード独立確認）成功、High/Mediumなし。全Worker最終結果はreport/results参照。旧candidate/ledger/journal/packet sourcehash・停止journalhash/5lock保持、API/鍵0、実品質改善未評価、本番v1/未使用20問不変。次は全4stage/24jobの新offline journalへ同判定/artifactを接続し全先行stage再評価とprefix計数を回帰、その後新manifestでtransport/3guard/有限実評価へ。今回stage0 controlをstage1やpaidへ転用しない。Projectの資料の更新: なし。


2026-10-16 全4stage/24job offline統合：[RAG_SUBJECT_ROLE_COMPARISON_REPORT.md](RAG_SUBJECT_ROLE_COMPARISON_REPORT.md)。新comparison contract/journalを追加し、固定2/6/8/8予約・完了・checkpoint・中立packet・元review再評価を全12pairへ接続。全先行collection/artifactを各操作/reopen/予約前に再採点し、checkpoint/packets_ready単独では次stageへ進めない。prefix/global計数と生成/監査完了を分離、予約196608microUSDは実費/実送信証明ではない。旧stage0との判定parity（pass/fail/unknown/unsupported/不正）を含むpure7+journal16=23成功、独立コード23・安全23成功、High/Mediumなし。全Worker最終結果はreport/results参照。初回source障害注入のnamed import捕捉不足をdefault fsへ揃えて回帰確認。旧全source snapshots/停止journalhash/5lock、本番v1/未使用20問を保持。API/鍵0、モデル品質未評価、dispatchAuthorized/transport/releasefalse。次は通信層sourceを固定した別live manifestでbounded transport/3guard/deadlineを接続し、通信mockと独立安全gate後に料金/新directory等preflight・最初の1pair有限実評価。今回offline runをpaidへ転用しない。Projectの資料の更新: なし。


2026-10-16 live bounded transport：[RAG_SUBJECT_ROLE_COMPARISON_LIVE_REPORT.md](RAG_SUBJECT_ROLE_COMPARISON_LIVE_REPORT.md)。OpenAI Docs/公式Structured Outputs確認後、別version2 live contract/journal/runnerを追加。旧offline不変、固定24body hashと凍結dispatch context、request/raw/最終保存JSONの3guard、UTF8/bytes/cancel/redirect、期限付きreserve/complete/finish/closeを接続。Planner Medium（同期hash/secret検査後にfetch直前の期限再確認なし）を修正し、timer先行作成→直前時刻/abort確認→dispatch加算/fetchとした。新回帰は同期secret検査中の期限超過fetch0・timeout・lockを確認。対象21/独立コード21・安全21成功、High/Mediumなし。全Worker最終結果はreport/results参照。close解除後の期限超過もmarker復元、保存不明は二重terminalなし。API/実キー0・CLI/loaderなし、今回mockだけ。旧全source snapshots/停止journalhash/5lock、本番v1/未使用20問保持、実互換性/品質/価格未評価。次は公式Luna料金/適用条件・最終source/manifest・新canonical run未使用・旧lockのpreflight後、別private entryから最初の1pairだけ有限実評価し独立意味監査。旧run/mock directory再利用や別path自動再送なし。Projectの資料の更新: なし。


2026-10-16 対象roleの実API比較stage0：[RAG_SUBJECT_ROLE_COMPARISON_API_RUN_REPORT.md](RAG_SUBJECT_ROLE_COMPARISON_API_RUN_REPORT.md)。通常枠利用可/並行作業なし、公式Luna料金・最終source/manifest・旧5lock/停止journal hash・新run未使用を確認。private entryのdefault検査誤りを送信前に修正し、独立Medium（存在確認後のstage進行race）をfetch直前の先頭2job/順序/bodyhash/stage0/最大2制限で閉じた。独立mock確認後に2送信/2形式完了/技術失敗0。中立packetの独立8観点監査で両版reviewed_match・元監査hashとreviewをprivate登録、最終8row chain/artifactを独立安全確認、High/Mediumなし。両版plan同一のため改善効果は未確認。比較済み1pair/12、人間goldpending、単一unitで複数unit未評価。usage推計0.000725725USD・実請求不明、予約16384microUSDは実請求上限ではない。従来5.412秒/修正3.034秒は保存開始まで・RAG全体や速度優位性ではない。後続予約/送信0、本番v1/未使用20問/旧5停止run保持、deploy等なし。コード不変で全テスト再実行なし、前工程全Worker1659成功を維持。次はsource/元review/runを再検証し、stage1専用送信上限付きentryで次の3pairだけ有限比較する。stage0 entryの再実行は禁止。Projectの資料の更新: なし。


2026-10-16 対象roleの実API比較stage1：[RAG_SUBJECT_ROLE_COMPARISON_STAGE1_REPORT.md](RAG_SUBJECT_ROLE_COMPARISON_STAGE1_REPORT.md)。通常枠利用可/並行作業なし、公式Luna料金と既存stage0元review/source/hashを再確認。stage1専用private entryでordinal2..7/順序/bodyhash/stage1/最大6のfetch前制限をmock・独立安全確認後、追加6送信/6形式完了/失敗0。中立packet6件を独立8観点・全対応候補で監査し全件reviewed_match、前文対象と後文属性/条件の対応・別対象別属性の独立要求を保持。同一対象の別出現をoracle代表位置と違うだけで誤り扱いせず確認。元監査hashとreviewを登録、23row chain/2段階元review/artifactを独立安全確認しHigh/Mediumなし。累計8送信/比較済み4pair、全4pair両版plan同一で改善効果未確認。追加usage推計0.001760925USD、累計0.002486650USD（実請求不明）、累計予約65536microUSDは請求上限ではない。stage2予約/送信0、本番v1/未使用20問/旧5lock/監査文書保持。コード不変で全テスト再実行なし、前工程Worker1659成功。次はsource/run/2段階の元reviewを再検証し、stage2の4pair（8送信：比較・計算・推薦・要約）を専用fetch上限付きentryで有限比較する。stage0/1 entryの再実行は禁止。人間gold/総合RAG品質は未完了。Projectの資料の更新: なし。


2026-10-16 対象roleの有限比較完了：[RAG_SUBJECT_ROLE_COMPARISON_STAGE3_REPORT.md](RAG_SUBJECT_ROLE_COMPARISON_STAGE3_REPORT.md)とSTAGE2_REPORT/各RESULTS.json。枠回復・並行作業なしを確認し、公式料金/固定source/run/先行元reviewを再照合。独立安全確認済みのstage2/3専用fetch上限entryで各4pair8送信、追加16送信全形式完了。中立packetを独立8観点/全候補対応で監査し24armすべて凍結抽出oracle相対reviewed_match、4元reviewを固定監査hashと照合登録。stage4/done・予約完了review24/比較12pair・generationComplete/allReviewsComplete=true、releaseAccepted=false。baseline12/12・候補12/12、改善優位性未確認。本番v1維持。全plan同一8pair/tasks同一10pair、対象不在index8/9はcandidate/needs_clarification・unresolved差があり、聞返し/回答可能性は今回のoracle対象外として未評価。次の問題として保持する。計算は要求抽出だけでoperand/演算未評価。全usage推計0.00727295USD（実請求不明）、予約196608microUSDは請求上限ではない。中央値3.560秒/最大7.467秒は保存開始まで、RAG全体ではない。コード/DB/本番設定変更・全テスト再実行なし、前工程Worker1659成功。旧5lock/停止hash/未使用20問/固定監査文書保持。全stage entry再実行禁止、追加有料runを作らない。次は質問文/履歴/指定scopeで対象が決まる場合と未解決の場合の聞返し期待値を、資料根拠不足/検索0と分けてoffline設計し独立レビュー。凍結oracleや元監査を変更しない。人間gold/検索回答/OCR100PDF/iPad総合品質は未完了。Projectの資料の更新: なし。


2026-10-16 聞返し判断のoffline設計：[RAG_CLARIFICATION_DECISION_DESIGN.md](RAG_CLARIFICATION_DECISION_DESIGN.md)とRESULTS.json。通常枠利用可/並行作業なし確認、現runtimeの指示語regex/previousQuestionとexplicitPageContextの計画上書き・eligible通過を調査。凍結v4/既存oracle/runと切り離し、要求抽出/対象解決/根拠状態を別軸、question_only/contextual_pre_search/scoped_inspectionの入力境界を整理した。22予定matrixで対象不要generic・省略・単一/複数履歴・話題転換・page全体/単数指示語・根拠不足/検索0/障害・認可失効を含める。独立Planner Medium（対象解決済みページ全体と内容取得の混同）をtargetState/nextAction分離で解消、技術unsupportedと意味不確実も分離し最終High/Mediumなし。文書/22連番/現source・完了runと4監査artifact hash不変を確認。コード/fixture/prompt/API/鍵/テスト再実行0、22case成功や実品質改善と主張しない。人間goldpending、本番v1・旧5停止run/未使用20問保持。次は列挙値/phase組合せ/部分要求の小契約を固定→別合成fixture/oracleの独立確認→pure evaluatorの順。新有料runはまだ開始しない。Projectの資料の更新: なし。


2026-10-16 聞返し小契約・別合成fixture：[RAG_CLARIFICATION_DECISION_CONTRACT.md](RAG_CLARIFICATION_DECISION_CONTRACT.md)とRAG_CLARIFICATION_FIXTURE_RESULTS.json。input/oracleを分離した新30case/22matrix/29意味要求/2評価器faultを作成。context scopeRef/revision/outcome、失効本文空、question-only/pre/post phase、対象/根拠/action別軸、部分要求を固定。検索failedは評価器technicalfaultと分け、原質問の既知対象を保持する。独立PlannerのMedium（複数講座一覧にも読める問いを単数と断定）をユーザー選択1講座の問いへ明確化しinputHash/根拠更新、許容tuple追加なし。最終独立注釈/コード安全High/Mediumなし、humanGoldとデータ内annotationReviewはpending維持。fixture整合対象8/全Worker1667/独立8成功、失敗skip0。これは実判定/モデル品質ではない。pure validator/意味review集計は未実装、uncertain意味正例も未収録。API/鍵0、本番v1/未使用20問/旧source/完了run/4監査artifact/旧5lock保持。次はpure validatorの入力/出力上限・不正参照/別scope/版/失効参照/矛盾tuple・uncertain形式正例/技術状態の回帰を実装、その後外部意味review集計。新有料評価は開始しない。Projectの資料の更新: なし。


2026-10-16 聞返しpure validator：[RAG_CLARIFICATION_VALIDATOR_REPORT.md](RAG_CLARIFICATION_VALIDATOR_REPORT.md)とRESULTS.json。新clarification-decision.mjsはnodecryptoだけで、rawJSONの全input hash/64K・出力32K/UTF8 scalar/phase/ctxID・scopeRef・revision・失効本文・basis kind閉包・対応scopeペア・target/action/purpose/evidence必要観測を検証する。oracle/IO/通信/keyなし。意味pending/技術自己申告真偽false/認可false/releasefalseを返し、正しい参照でも架空label/要求欠落/false支持が形式通過する反例を残した。uncertain形式正例・正当な同一state複数decision・部分要求も回帰。対象13/全Worker1680/独立契約13・コード安全21（fixture8含む）成功、失敗skip0、High/Mediumなし。旧fixture/小契約/source/完了61行run/4監査artifact/5停止lock不変、API/鍵0、本番v1/未使用20問不変。次は外部意味reviewをinput/decision/oracleへbindして要求対応・聞返し漏れ/余分な確認・技術状態不一致を保留込み集計するpure module。形合格や30fixture roundtripを実モデル品質としない。prompt/有料run/runtime接続は後gate。Projectの資料の更新: なし。


2026-10-16 手動再開・聞返し意味review集計：[RAG_CLARIFICATION_REVIEW_REPORT.md](RAG_CLARIFICATION_REVIEW_REPORT.md)とRESULTS.json。自動実行PAUSEDは維持。新pure moduleがinput/decision/oracleの3hashへ外部8観点reviewをbindし、最大一対一matchingのmissing/extra上下限と外部actionAssessmentの過不足/未確認を集計する。確定failもreviewCompleteにでき、適合と採点完了を分離。tuple/参照の全pass矛盾・実action分類/承認matchingとの矛盾を拒否。技術自己申告不一致はtechnical_mismatch、一致nonokもtechnical_unassessedで意味pass不可。harness/reviewer本人性・人間gold・releaseはfalse。artifact原文hash照合/保持は将来caller責任。対象13/全Worker1693/独立契約13・コード安全最終13（関連33も追加前成功）・失敗skip0、High/Mediumなし。30caseは合成reviewのroundtripで実モデル品質ではない。既存fixture/validator/小契約/完了run4artifact/旧停止run不変、API/鍵0、本番v1/未使用20問不変。次はgold/harness/reviewを含めずinputだけから別candidate request/output schemaを設計し、独立安全確認してから別有限評価。runtime接続/新有料runはまだ行わない。Projectの資料の更新: なし。


2026-10-16 聞返しcandidate入出力設計：[RAG_CLARIFICATION_CANDIDATE_IO_DESIGN.md](RAG_CLARIFICATION_CANDIDATE_IO_DESIGN.md)。モデルへ渡すのは検証済みinput/hashだけ、固定指示とstrict schemaを分離する設計。モデルwireはtechnicalState okのみとし評価器fault2件はローカル専用、モデル対象28case/29要求。refusal/不完全/形式違反は別技術結果で母数保持し、意味reviewへ捏造decisionを渡さない。OpenAI Docs本文を確認、実API受理/品質は未確認。fixture/validator凍結hash・件数・差分空白を確認。文書のみで全Worker再実行なし、前工程1693成功は過去結果。自動実行PAUSED・API/鍵0・runtime/prompt/既存run変更なし。次はpure builder/schemaの実装と非混入テスト、その後parser・独立安全確認・別有限run設計。Projectの資料の更新: なし。


2026-10-16 Docling/Zod初期導入：[RAG_DOCLING_ZOD_ADOPTION.md](RAG_DOCLING_ZOD_ADOPTION.md)とRESULTS.json。Docling2.139.0を専用local環境へ導入し、explicit models/offline PDF CLIで構造要素・物理page・表セル・bboxを保持、pages配列も出力する。実装者/親が合成実2page/2tablesを変換確認、既存chunkerへ接続するローカル確認成功。iPad自動経路は未接続、OCR/数式はoff、100pageはmock境界検証のみ。Zod4をrubric/grade/reviewの送信schema・受信検証へ接続し旧wire exact parityを確認。型/未知/欠落/拒否/未完了/size不正は既存error・予約返還へ、再生成なし。聞返しcandidateの別Zod builder/parserを追加し旧validator併用、provider/model/error/usage/reasoning検証不足Mediumを独立Planner指摘で修正。対象JS50/全Worker1707/Python16/独立契約50・安全JS50/Python16成功、失敗skip0、最終High/Mediumなし。凍結fixture/validator/reviewと完了manifest不変。API/鍵0、公開依存/モデルの明示準備のみ。次はDocling日本語・OCR/数式と実100page評価、アプリへの自動接続設計（認可/同意/削除/文書対応）、candidate有限評価。自動実行PAUSED、deploy/migration/push/mergeなし。Projectの資料の更新が必要: [設計] HYBRID_RAG.md。複製置き場の変更なし。


2026-10-16 Docling後の本文限定分割：[RAG_STRUCTURE_AWARE_CHUNKING.md](RAG_STRUCTURE_AWARE_CHUNKING.md)とRESULTS.json。新localchunk pipeline/--chunks-output/semantic_manifestを実装。text/paragraphだけ意味境界（明示原文bind vectors時）→再帰400推定/overlap最大65、表図式・見出しcaption等はprotectedで保持。原文element/page/Unicode範囲/provenance/explicitrefsを残し、未解決関係を推測しない。vectorsなしはno_vectors明示、別段落の意味統合や再梱包なし。独立reviewでpage review/OCR状態消失・明示vector JSONnullのsilentfallbackを修正し、共通globalcaps/dupID検証も強化。最終Python34/独立契約34/安全34成功、High/Mediumなし。実合成2page/4本文chunk/2表保護・親も別実解析で原文範囲/private600確認。実embeddingの意味品質/本番検索改善は未評価。Worker/iPad/旧indexformat・凍結評価hash/完了manifest不変、全Worker再実行なし（前工程1707成功）。API/鍵/モデル追加取得0、自動実行PAUSED、deploy等なし。次はlocalchunk品質比較と、新構造chunksを再分割せず索引へ接続する設計、実encoder/日本語/図式/100page評価。Projectの資料更新が必要: [設計] HYBRID_RAG.md。複製置き場は未変更。


2026-10-17 Docling metadata追加：local `--chunks-output`に解析方式/PDF namespace・要素種別/ページ/要素座標/明示見出し関係/原文範囲/確認状態と独立metadata digestを追加。本文・既存chunk ID・semantic bindingは維持。metadataは認可情報ではなく、bboxは要素全体。Python43成功、実合成2page/本文4chunk/表2保護/整合/private0600確認。詳細: [RAG_METADATA_ADDITION.md](RAG_METADATA_ADDITION.md)。D1/Vectorize保存と検索/出典/iPadへの接続は次工程で未実装。API/鍵/追加モデル/本番操作なし、自動実行PAUSED維持。


## 構造chunkの保存・出典接続（2026-10-17、ローカル検証）

Doclingの本文chunkと保護要素を受け取るoptional structure入力、strict検証、D1 metadata_json保存、metadataを保持した移動・更新・削除、認可済み検索結果の出典投影を実装。既存pagesは互換、新形式は再分割しない。新形式のpage/context hashにmetadataをbindし、本文同一ならvector再利用、更新前proofは新IDで失効する。Python private exporterは全資料preflight後に最大5page/240KiBのbatchを生成し、送信しない。詳細と制約は [RAG_STRUCTURED_INGESTION.md](RAG_STRUCTURED_INGESTION.md)。DB migration0009は追加ファイルのみでremote未適用、deploy/iPad自動接続/座標ジャンプUIは未実施。図/未知/要OCR/要確認/空page/過大要素を含む資料は初版で全export拒否。tableセル本体はlocalのみ、検索はMarkdown。出典bboxは元要素全体、文字範囲は保存chunk全体で切り詰め後のexcerptを指さない。自動実行PAUSED維持。
