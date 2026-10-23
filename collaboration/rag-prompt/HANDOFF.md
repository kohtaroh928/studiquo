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
