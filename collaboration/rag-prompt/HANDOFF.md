# プロンプト担当の引き継ぎ

最終更新: 2026-10-18。環境準備: Codex。候補担当: 友人（未着手）。

- 現在地: docs/RAG_COLLABORATION.md、キー不要のcheck/prepare、example候補と形式/固定入力のテストを準備。
- 実施: workspace3件＋既存baseline7件の10テスト成功。HEADのクリーンな書き出し＋このkitでnode_modules/credentialsなしのcheck/prepareを確認。12組の固定入力一致、同名run上書き拒否、無効run名3件拒否を確認。友人PCの検証は未実施。
- 新API回答生成/品質結果: なし。有料API0回。exampleは未採用。
- 次の一手: 公開済みkitを独立cloneし、自分のbranchでcheck/test。候補一つと原子的採点計画を作る。
- Notion: 初回候補タスク https://www.notion.so/3fc5d67983c381fa9008e37723e0ca04 （未着手）。共通RAGカードに環境準備を記録。担当選択肢に友人がないため未設定、本人のAIログイン・Notion接続も未確認。
- 実行中の生成process: この準備では開始していない。

## 2026-10-18: 評価キー共有の準備

ユーザーが既存評価キーを友人の担当作業でも使用することを依頼。API_ACCESS.mdへ料金・共有方法・予算/停止条件を整理。Luna入力$0.10/出力$0.50 per million、入力20k/出力8192仮定で24/72/360callsは約$0.15/$0.44/$2.20。初回$1/友人月$5は提案のみ。共有経路/友人PC設定/実行adapter/予算承認は未完了。秘密値は読取・複製せず、有料API0回。

## 2026-10-19: 採点表と採点スクリプト（Claude）

- 追加: candidates/requirement-coverage-v1.json、rubric-fixed6.json、score.mjs、score.test.mjs。Node 24で score/workspace の9テスト成功。
- 回答生成は未実施。有料API0回。このクラウド環境からはapi.openai.comへ接続できない（ネットワーク設定で拒否）。
- 次の一手: 生成手段（Luna/実行場所/予算）を決め、36回答を保存してscore.mjsで予備判定→人が確定。
- Notion: この作業環境にNotion接続がなく未記録。
- 追加: run-luna.mjs（有料生成。明示opt-in、同時1、再試行なし、初回失敗で停止、送信前に費用予約、journalで再開、回答は.localに0600）とテスト4件。モックのみで確認し、実APIは未送信。
  実行例（Node 24、キーは環境変数のみ）:
  `STUDIQUO_RAG_PROMPT_REMOTE=true STUDIQUO_RAG_EVAL_OPENAI_KEY=... node collaboration/rag-prompt/run-luna.mjs trial-01 example,requirement-coverage-v1 --max-calls 36 --budget-usd 0.5`
  採点: `node collaboration/rag-prompt/score.mjs collaboration/rag-prompt/.local/trial-01/answers.json [manual.json]`

## 2026-10-19: trial-01 実行と採点（Claude）

- `run-luna.mjs trial-01 example,requirement-coverage-v1 --max-calls 36 --budget-usd 0.5` を1回実行。36回すべて成功、再試行なし、モデルはgpt-6-luna。トークンからの概算約$0.019。
- 結果: `results/trial-01.md`。生の回答は実行環境の`.local/`のみ（コミットしない、クラウド環境なので残らない）。
- 要点: requirement-coverage-v1はp3-delta（Fが2時間長い）を改善。全プロンプトでv01-rule（2月1日以降の適用条件）とnp-conclusion-first（結論を先に）が欠落。explainで補足が一切付かず補足は評価不能。
- 採点表のlm-same・p3-no-verdictのパターンに取りこぼしあり（未修正）。
- 次の一手: 採点パターンの修正、v01-rule/結論先出しを指示に足した候補で再実行、複数回実行で揺らぎを見る。
- Notion: 接続なしで未記録。

## 2026-10-26: 採点表v2と候補v2（Claude）

- run-luna.mjs が workspace.mjs を読んでいて、.ts化（c427b7b）以降起動できなかったため workspace.ts に修正。
- 採点表を fixed6-atomic-v2 に更新（lm-same「差はありません」等、p3-no-verdict「判断できず」）。テスト1件追加、Node 24で24件成功。trial-01を再採点し、要確認21→14行で人の確認と一致（results/trial-01.md）。trial-01の取りこぼしは9行ではなく7行だったので訂正。
- candidates/requirement-coverage-v2.json を追加: v1に「適用条件（日付・版・対象・測定条件）を一文添える」「判断できないときは結論と理由を先に」を追加。workspace.ts check 成功。生成は未実施、有料API0回。
- 次の一手: baselineとv2で trial-02（24回×3回、予約は1回あたり約$0.117、実費の概算は合計約$0.04）。承認後に実行。

## 2026-10-26: trial-02 実行（Claude）

- baselineとrequirement-coverage-v2を固定6ケース×2style×3回(trial-02a/b/c、72回、全成功、概算約$0.038、gpt-6-luna)。結果: `results/trial-02.md`。
- 要点: v2はp3-delta欠落5/6→2/6、v01-rule 4/6→2/6、結論先出しの後置き6/6→2/6。一方v01-basis(開催日で判定)が0→2/6、np-same-priceが0→1/6で落ちた(source_only)。違反0件。3回なので揺らぎの範囲を出ない。
- 採点表の取りこぼし1件: p3-f-price-unknownが「Fは資料で確認できません」を拾えない（未修正）。
- 次の一手: v01-basisとnp-same-priceを落とさない文言のv3を作るか、v2を暫定候補とするかを決める。有料API追加は承認後。
- Notion: カード更新済み。

## 2026-10-26: trial-03 実行（Claude）

- `candidates/requirement-coverage-v3.json` を追加(v2+「比較できなくても共通点は述べる」「判定基準も残す」)。baselineとv3を3回(trial-03a/b/c、72回、全成功、概算約$0.039、gpt-6-luna)。結果: `results/trial-03.md`。
- 要点: v3は v01-basis と np-same-price をv2より戻し(0/6)、結論先出しとp3-deltaは保ったが、v01-rule(日付)がv2の2/6から4/6に戻った。違反0件。v01-rule と v01-basis の両方を満たしたのは6回答中2回。
- 採点表の取りこぼし2件（np-same-priceの語順、p3-f-price-unknown）は未修正。
- 次の一手: 指示の調整を続けず、別の合成ケース(追加練習問題)を足して傾向を確認する。足し方は統合担当と合意。

## 2026-10-26: 追加ケースの設計案（Claude）

- `EXTRA_CASES.md` を追加（設計案のみ）。凍結6ケースは変えず、`extra-cases/` に別ファイルで置く案。型8個、8〜12ケース、概算約$0.08（144回）。ケース本体・コード変更は未作成、有料API0回。
- 次の一手: 統合担当（kohtaroh928）と、ケース作成者・レビュー担当・コード変更の範囲を合意。

## 2026-10-28: 追加ケースの実装と評価（Claude）

- PR #81(ツール: `--cases extra` / `--rubric extra` / 捕捉スクリプト)、PR #82(ケース8件と採点表。作成は候補指示と過去結果を見ない別のClaude)。ユーザーの代理許可(kohtaroh928さんの確認事項4点)に基づく。
- 評価: baseline/v2/v3 × 8ケース × 2style × 3回。結果: `results/trial-extra-01.md`。e4・e8は本番の検索で資料が渡らず初回144回を無効にして再実行(合計約$0.136、承認の約$0.08を超過)。
- 要点: v3は e1 で適用日を6/6落とし(baseline・v2は2/6)、固定6の v01-rule と同じ現象。v3は e2 でAの値・Bのページ数を残す回答が増えた。結論先出し(e3)はどの指示でも効かない。根拠違反(資料にない値)はなし。explainの補足は初めて評価でき、表示・位置とも問題なし。e5〜e8の大半は差が出ない。
- 採点表の取りこぼし3件(e4-unit-value、e3-fee-same、e8-bep-unknown)は未修正。
- 次の一手: v2を既定候補とするか、v3の「判定基準を残す」文言を直すかを決める。

## 2026-10-29: v4・v5 の作成と評価（Claude）

- ユーザー方針: 「別途かかります」のぼかしと、適用日の欠落を漏れとして数える。精度を上げるため指示文を直す。
- `candidates/requirement-coverage-v4.json`・`v5.json` を追加。追加8・固定6を3回ずつ評価(約0.176ドル、1件タイムアウト)。結果: `results/trial-v4v5-01.md`。
- 要点: 追加8の回答漏れ(厳しい数え方)は v2 11.5% → v5 1.8%、比較できないときの言い切りは 0/12。ただし適用日の欠落は残る(v5: 追加8で2/6、固定6で3/6)。v4・v5は追加8を見て直したため、追加8の数字は過剰適合を含む。
- 次の一手: 適用日は本番の方針文側で扱うか決める。未見の新ケースで v5 を確認する。

## 2026-10-29: 方針文の複製を直す案（Claude）

- ユーザー指示: 本番ではなくキットの中で試す。`policyEdits`（方針文の複製の差し替え）を候補JSONに追加（`workspace.ts`、テスト28件）。本番の `answer-policy.ts` は変更なし。
- 候補 `policy-date-start-v1`（適用日の1行だけ）と `policy-date-start-v5`（それ + v5の追加指示）。結果: `results/trial-policy-date-01.md`。
- 要点: policy-date-start-v5 は追加8の回答漏れ0.6%、適用日の欠落 1/6（追加8）・1/6（固定6）、結論先出しも0/6。ただし追加8を見て作った指示で過剰適合を含む。累計費用は約0.49ドル。
- 次の一手: 未見の新ケースで確認。良ければ本番反映を別PRで提案（承認が必要）。
