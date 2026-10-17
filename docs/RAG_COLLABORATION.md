# RAG共同開発の始め方

2026-10-18。あなた＝RAG本体の統合担当、友人＝プロンプト候補・回答品質評価担当として始める。利用する開発AIはClaude CodeでもCodexでもよい。担当は人で決め、AIを変えても担当範囲は維持する。

## 1. 分担と変更場所

| 担当 | 最初の仕事 | 編集範囲 |
| --- | --- | --- |
| 統合担当（あなた） | 原PDF自動Docling解析、同意・認可・費用予約・取消削除、iPad接続、意味encoder | services/、tools/docling/、mcp-server/src/、studiquo/とそのテスト |
| プロンプト担当（友人） | 固定した根拠で回答漏れ・条件/例外/単位・source_only/explainを比較 | collaboration/rag-prompt/candidates/、HANDOFF.md、PROPOSAL.md |
| お互い | 相手の変更をレビューし、採用/不採用の根拠を確認 | GitHubのPR。自分の変更だけで本番採用を決めない |

友人は本番answer-policy.js、検索・認証・課金、凍結baseline、評価bank/goldを変更しない。評価ツールの変更が必要なら別PRとして統合担当と対象ファイルを合意する。新候補は一度に一つの仮説に絞る。

## 2. 友人のPCでのセットアップ

まずGitHubの招待受諾と通常のGit認証を済ませる。Node.js 24系とGitを用意する。最初のプロンプト作業にはXcode、Python、Docker、Cloudflareアカウント、OpenAI APIキーは不要。Node 24系は既存の評価環境に合わせたもので、「常に最新の推奨版」という意味ではない。

既存の作業フォルダを上書きせず、新しい空き場所で実行する。

```sh
git clone --branch codex/rag-wip https://github.com/kohtaroh928/studiquo.git studiquo-rag-prompt
cd studiquo-rag-prompt
git status --short
git switch -c codex/rag-prompt-completeness
node --version
node collaboration/rag-prompt/workspace.mjs check
node --test collaboration/rag-prompt/workspace.test.mjs
```

この共同開発キットがGitHubへ保存されてからcloneする。見つからない場合はmainへ切り替えて代用せず、統合担当へ公開したbranch/commitを確認する。同名の作業branchが既にある場合は別名を使う。統合担当の既存rag-wip worktreeを友人と共有しない。

任意: Worker側テストも担当する場合だけ、mcp-serverで次を実行する。依存導入にはネット接続が必要だが、通常のテスト自体は有料AI評価ではない。ローカルNode 24で互換確認済みのlockを使用する。

```sh
cd mcp-server
npm ci
npm test
cd ..
```

Claude Codeは自分の通常アカウントでこのcloneを開き、`claude`から `collaboration/rag-prompt/START_PROMPT.md` の文章を渡す。Codexでは同じcloneをプロジェクトとして開き、同じ文章をチャットへ貼る。統合担当用の `tools/resume-rag-claude.sh` と `docs/RAG_RESUME_PROMPT.md` は友人の並行作業に使わない。

AIの契約・利用枠は各自のものを使う。CLIの認証ファイルや開発AIのログイン情報は共有しない。開発AIの利用枠と、アプリ評価用のOpenAI API利用料は別である。

## 3. 最初の課題とローカル確認

`collaboration/rag-prompt/PROPOSAL.md` の仮説と受け入れ条件を読む。exampleは動作確認用の未採用候補で、品質改善が確認された版ではない。自分の候補を作る。

```sh
cp collaboration/rag-prompt/candidates/example.json collaboration/rag-prompt/candidates/completeness-v1.json
# idとadditionalInstructionsを編集する
node collaboration/rag-prompt/workspace.mjs check completeness-v1
node collaboration/rag-prompt/workspace.mjs prepare completeness-v1 trial-01
```

prepareは `.local/trial-01/pairs.json` と `review.json` を新規生成する。既存runを上書きしない。別の候補/試行には新しいrun名を使う。.localはGit対象外。stdoutはhash/件数だけで、資料/回答を出さない。

固定済みの合成6ケース×2styleの12組を作る。各組の質問・履歴・検索結果・生成設定は同一で、凍結プロンプト末尾への候補指示の追加だけを変更する。全開発30問や実検索の評価ではない。未使用20問はこのキットから読み込まない。古い凍結版との比較であり、本番最新版との比較が必要になったら、その時点の本番版を別途固定して再確認する。

この処理では回答を生成しない。Claude/Codexに文章を読ませた所感やローカルテスト成功を、LunaのAPI比較結果や正答率と呼ばない。

## 4. 回答生成・評価に進むとき

最初はAPIを使わず、要求項目と候補指示のレビューまで進められる。有料生成は次を合意してから、既存の評価用runnerの適切なadapterを別工程で確認する。このキットにはネットワーク実行機能を入れていない。

- 資料/質問/根拠/基準promptのhash、候補hash、モデルと生成設定
- ケース数、両styleと両候補の実呼出数、反復回数、retryを含む費用上限、停止条件
- 実行担当とAPI project。友人に必要な場合は本人用/専用projectのキーを秘密として渡す。本番CloudflareやRevenueCatの資格情報は不要
- 必須項目を原子的に分けた採点表、根拠の支持範囲、独立review担当

生成側へ正解・gold・採点文言を渡さない。評価は回答生成者とは別の人/AI視点で行い、不明はpendingにする。空のreviewを合格にしない。既知の過去回答の欠落3件を、現行Lunaの失敗率として扱わない。開発30問と未使用20問を区別し、未使用20問を読んで調整しない。新しい合成ケースは追加練習問題として明示し、未使用テストと呼ばない。

raw回答・prompt・実資料・キーはGit/Notion/共有PRへ載せない。公開できる成果は合成候補指示、変更意図、件数、hash、採点項目単位の集計と限界。実際の証拠は適切なprivate保存先でreviewする。

## 5. 日々の進め方とPR

1. 自分のbranch/statusとNotionの担当タスクを確認し、対象ファイル・完了条件を書く。
2. 小さな候補を一つ作り、check/testを実行する。
3. 自分の `collaboration/rag-prompt/HANDOFF.md` に変更・検証・未実施・次の一手を残す。共通のRAG_CLAUDE_HANDOFFは友人が同時編集せず、統合担当がPRから要点を取り込む。
4. commit/pushを依頼または明示承認した範囲で実施する。自動で一括addやpushしない。手動例は以下。
5. PRのbaseはまず **codex/rag-wip**。main向けにはしない。変更した本人以外がreviewし、統合担当が採用を決める。base branch更新後は無理に履歴を合わせず、通常のmerge/衝突解消で既存変更を保持する。

```sh
git diff --check
git diff -- collaboration/rag-prompt
git add collaboration/rag-prompt/candidates/completeness-v1.json collaboration/rag-prompt/PROPOSAL.md collaboration/rag-prompt/HANDOFF.md
git commit -m "docs(rag): propose completeness prompt candidate"
git push -u origin codex/rag-prompt-completeness
```

PRには目的、baseline/candidate hash、検証条件、結果/未実施、回帰・費用・限界を書く。productionへの反映PRは統合担当が別に作る。プロンプトを変えるだけでも、資料忠実性や過剰補足の悪化がないか確認する。

Notionは既存「RAG回答の残る弱点を評価・改善する」に関連付け、友人の初回候補タスクを一つ割り当てる。友人のNotion表示名は本人確認後に設定し、AIが知らない担当者を推測で選ばない。接続がない場合はHANDOFFに未記録と書く。

## 6. 完了条件と現在の準備状態

キットのoffline check、12組の固定入力一致、候補の形式/容量検証、再現性をローカルで確認する。友人自身のPCで同じ確認が通り、PRを作成して相互reviewできれば、共同作業のセットアップ完了。

友人のPC・GitHubログイン・AIログイン・Notion権限は今回操作していない。branch protectionやCI自動実行も追加していない。今回の準備だけでは有料API評価を実施済みとしない。
