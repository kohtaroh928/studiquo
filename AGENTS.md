# Studiquo Agent Instructions

このファイルはCodex、Claude Code、そのほかの開発エージェントが常に読む最小ルールである。
詳細な開発工程は`docs/DEVELOPMENT_WORKFLOW.md`を正本とし、必要な場合だけ読み込む。

## 常に守るルール

- ユーザーの明示的な依頼を優先し、依頼された範囲を越えて変更しない。
- 作業前に関連コードと`git status`を確認し、既存の未コミット変更を上書き・破棄しない。
- APIキー、トークン、個人情報、学習内容をコード、ログ、テストデータ、コミットへ入れない。
- 破壊的操作、push、merge、release、deploy、ストア提出、本番データ変更は、明示的な依頼なしに行わない。
- 完了を主張する前に、変更内容に比例した検証を行い、未実施項目と残るリスクを報告する。
- 認証・認可、課金、個人情報、データ削除・移行、本番設定などのHighリスク変更では、モードにかかわらず安全確認、ロールバック検討、独立レビューを省略しない。
- 設計・構成・公開状態に関わる変更の完了報告には、`docs/PROJECT_SYNC.md`に照らして、claude.ai Projectへ渡している資料の更新が必要なファイルを添える。該当がなければ「Projectの資料の更新: なし」と書く。置き場のファイルの更新は、依頼があったときだけ行う。

## GitHub Projectでのタスク管理

- Studiquoのタスク管理先は[GitHub Project「Studiquo タスク」](https://github.com/users/kohtaroh928/projects/1)(所有者 `kohtaroh928`、番号 1、非公開)。2026-10-25にNotionから移行した。Notionの「Studiquo タスク」データベースは移行前の記録として残るが、更新しない。
- 項目はリポジトリのIssueではなく、プロジェクト内のドラフト項目にする。公開リポジトリに残件の詳細を出さないため。
- フィールド: 状態(`アイデア`・`未着手`・`あなた待ち`・`進行中`・`監視中`・`完了`)、作業の種類、重要度、領域、担当(`薮崎`・`長瀬`・`Claude`・`Codex`)、リンク、NotionURL(移行元)、Notion作成日。本文に「次の一手」と「経緯・結果」を書く。標準の `Status` フィールドは使わない。
- 操作は `gh project` で行う(要 `project` スコープ。無ければ `gh auth refresh -h github.com -s project` を人に依頼する)。例: `gh project item-list 1 --owner kohtaroh928 --format json`、`gh project item-create 1 --owner kohtaroh928 --title ... --body ...`、`gh project item-edit`(フィールドIDは `gh project field-list 1 --owner kohtaroh928` で得る)。
- ChatGPT/Codex/Antigravityも、依頼された作業と作業中に判明した残件をここに記録する。着手時に既存項目を検索・確認し、該当するものを更新する。新しい作業・残件だけを追加する。同じタスクを別に作らない。
- 担当は、Codexなら `Codex`、Claudeなら `Claude` を使う。他の担当を根拠なく変更しない。PR・コミットなどの根拠はリンクに書く。
- 実装・テスト・マージ・デプロイ・実機確認を区別して記録し、必要な確認が残る間は完了にしない。人間の操作や判断が必要なら、次の一手を具体的に書いて `あなた待ち` にする。
- 終了時は確認できた結果・残件・次の一手を更新する。既存の経緯を保持し、秘密情報・個人情報・学習内容を書かない。GitHubに接続できない場合は未記録と明示し、記録できたと主張しない。
- Notionの[議事録・ドキュメント](https://www.notion.so/88893da381394586ba1485f7853ce185)は当面Notionのまま。タスクの管理先だけが変わった。

## 作業ブランチと作業フォルダの分離

ClaudeとCodexなど複数のエージェントの作業が被らないよう、次を守る。

- メインのチェックアウト(`~/studiquo`)では編集・コミットしない。読み取り、統合、実機確認の「確認枠」(`scripts/verify-slot`)専用とする。
- 作業は必ず`git worktree`で行う。`git worktree add .worktrees/<task> -b <claude|codex|antigravity>/<task> main`
  - Codexのアプリが作る`~/.codex/worktrees/`配下も可。
- ブランチ名は`claude/<task>`、`codex/<task>`または`antigravity/<task>`とする。他エージェントの接頭辞のブランチはcheckout・コミットしない。
- 着手前に`git worktree list`で同じ`<task>`や同じ対象ファイルが使われていないか確認する。被る場合はユーザーに確認する。
- 作業が終わり統合したら、worktreeとブランチを片付ける。
- `.githooks/`が上記を機械的に強制する。有効化は初回に`git config core.hooksPath .githooks`。人が意図的に回避する場合のみ`STUDIQUO_ALLOW_SHARED_CHECKOUT=1`を付ける。エージェントが勝手に付けてはならない。

## 実機確認の流れ(mergeの前に確認する)

アプリ(`studiquo/`)の見た目や動作を変えたら、mergeの前に、ユーザーが実機で確認できる状態にする。確認は「確認枠」で行う。

- **確認枠**は、メインのチェックアウト(`~/studiquo`)を、確認のあいだだけ使う仕組み。Xcodeで開くのはいつもメインの`~/studiquo/studiquo.xcodeproj`1つで、スキームは`studiquo-staging`(ステージング接続。本番のアプリやデータには触れない)。
- 編集とコミットは自分のworktreeで行う。確認はその変更をコミットした後で、予約札を取ってから始める。確認用のWIPコミットは作ってよい。pushとmergeは確認後。
- 手順:
  1. 変更をworktreeでコミットし、ビルドが通ることを確認する。
  2. `scripts/verify-slot acquire <ブランチ>`で札を取る。メインのフォルダがそのコミットに切り替わる。取れなければ(使用中、またはメインに未コミット変更あり)、ユーザーに状況を伝えて指示を待つ。
  3. ユーザーへ次の3点を伝える: Xcodeで`~/studiquo`を開いて`studiquo-staging`をRunすること、どのブランチのビルドか、どの画面のどこが変わったか。
  4. ユーザーの確認が終わったら`scripts/verify-slot release`で札を返す。メインのフォルダは元の状態に戻る。
  5. 問題なしの場合だけ、PRとmainへのmergeに進む。修正が要る場合は、worktreeで直して1からやり直す。
- **まとめて確認する場合(荷台)**: 修正のたびに`scripts/verify-slot add <ブランチ>`で「荷台」(確認待ち)に入れ、確認する段階で`scripts/verify-slot acquire --queue`を1回実行する。荷台のブランチを、`main`の上に入れた順で重ねた状態(メインのフォルダ上のdetached HEAD。元のブランチは変更しない)で札が取れる。
  - `scripts/verify-slot queue`で中身、`remove <ブランチ>`で取り外し。荷台に入れるのは、コミット済みでビルドが通ったブランチだけ。
  - 重ねる途中で衝突したら、札は取らずメインを元に戻して止まる。どのブランチが原因かをユーザーに伝え、直すか外すかを決めてもらう。
  - 札の使用中に`add`しても、今の確認には反映されない。確認中に中身を変えない。
  - 確認結果は、問題が出たときに原因を絞れるよう、表示される重ねた順とコミット一覧で伝える。問題なしのブランチだけを1つずつPR・mergeする。
  - `release`で荷台は空になる。続けて確認するものは`add`し直す。荷台はmainに入れない。
- 札は`.git/studiquo-verify.lock`、荷台は`.git/studiquo-verify.queue`(どちらもgitの管理外、全worktree共通)。`scripts/verify-slot status`で、誰がどのブランチで使っているか、何時間経ったかを見られる。4時間以上たった札は、使用者かユーザーに確認してから返す。他のエージェントの札を勝手に消さない。
- 確認枠は編集しない。切り替えはdetached HEADで行うので、他のworktreeが使っているブランチでも確認できる。確認枠にいる間、メインのフォルダでコミットしない(`.githooks/pre-commit`が止める)。
- 確認が終わったら、札を返す前に、メインのフォルダへ変更が残っていないかを`git status`で見る。
- 変更の有無を答える前に、XcodeがどのフォルダのどのコミットをRunしたかを確認する(`osascript -e 'tell application "Xcode" to get path of workspace document 1'`と、メインのフォルダの`git log -1`)。反映されない原因の多くは、開いているフォルダや切り替え先が違うこと。
- サーバー(`mcp-server/`)の変更は、ステージングのWorkerへ配備してから実機確認する。アプリだけの変更では配備しない。

### 実機確認で衝突しないための決まり

- `studiquo-staging`のBundle IDは1つ(`com.yabuko.studiquo.staging`)で、端末のステージング用アプリも1つ。確認枠の札で、同時に確認するのを1つのブランチに限る。
- 札を持っていないエージェントは、確認枠を切り替えない。`scripts/verify-slot`を使わずにメインのフォルダでブランチを切り替えない。
- ユーザーがworktreeのプロジェクトを直接開いてRunする場合は、そのworktreeとブランチを必ず伝え、札は取らない代わりに、そのRunが端末のステージング用アプリを上書きすることを添える。
- 同じ画面・同じファイルを複数のエージェントが同時に変更しない。着手前の`git worktree list`で対象ファイルが被るか確認し、被るなら先に統合を済ませるかユーザーに順番を聞く。
- mainが進んだら、確認前に`origin/main`を取り込んで、最新のmainに対する見た目を確認する。古いmainのまま確認すると、merge後に見た目が変わることがある。
- `.xcodeproj`は各フォルダで`xcodegen generate`により作る(`scripts/verify-slot`が確認枠で自動で行う)。他のフォルダの`.xcodeproj`やDerivedDataを編集・共有しない。

## 開発手順モード

ユーザーはチャットの最初または途中で、次のいずれかを指定できる。

### `開発手順: full`

- `docs/DEVELOPMENT_WORKFLOW.md`を最初から最後まで読み、詳細手順に従う。
- 要件、受け入れ条件、設計、実装計画、テスト、独立レビュー、引き渡しまで実施する。
- Standard以上の機能追加、大きな変更、リリース準備に使用する。

### `開発手順: lite`

- 詳細手順は自動では読み込まない。
- 関連箇所を調査し、スコープを確認して実装し、対象テストと差分確認を行う。
- 通常の小規模な機能追加、不具合修正、UI調整に使用する。

### `開発手順: off`

- 詳細手順を読み込まず、依頼された回答または作業だけを行う。
- 調査、説明、アイデア出し、文言修正など、正式な開発工程が不要な作業に使用する。
- 「常に守るルール」とHighリスク変更の安全確認は無効にならない。

## モードが指定されていない場合

- 既定は`lite`とする。
- 読み取りだけの質問、説明、調査は`off`相当で扱ってよい。
- Highリスク変更または大規模な設計変更は`full`へ引き上げ、詳細手順を読む。
- モードを引き上げた場合は、その理由をユーザーへ短く伝える。

## プロジェクトの前提

- `studiquo/`: iPad向けSwiftUIアプリ。SwiftData、認証、課金、手書き、PDF、AI連携を含む。
- `studiquoTests/`と`studiquoUITests/`: iOSのユニットテストとUIテスト。
- `mcp-server/`: Cloudflare Workers上のAPI・MCP・認証・AIプロキシ。
- `project.yml`: XcodeGenの正本。変更後は再生成し、Apple Sign InとCloudKitのCapabilitiesを確認する。
- アプリとサーバーは独立して更新されるため、API変更では新旧バージョン間の互換性を検討する。


## RAG担当の交代

- RAGをCodex/Claudeなど別担当から引き継ぐ際は、`docs/RAG_CLAUDE_HANDOFF.md`を最初に読み、実ファイル・ブランチ・作業中processと照合する。再開promptは`docs/RAG_RESUME_PROMPT.md`。
- CodexはRAG関連の作業を終えて最終応答を返す前に、毎回`docs/RAG_CLAUDE_HANDOFF.md`を更新する。実装・調査・テスト・文書修正・途中中断も対象とし、更新のための確認は不要。重要な区切り、担当交代前、使用量制限が近いときにも更新する。
- 更新内容は、最終更新・今回行ったこと・現在地・次の一手・今回の検証と未実施項目・未解決/実行中process・GitHub Project記録。進捗がなければその事実と理由を記録する。古い成功結果を再実行済みと書かず、現在地の要約を最新に保つ。
- 同じworktreeで複数担当を同時に編集させない。交代は自動スケジュール再開や公開操作の許可にはならない。

## RAGの並行共同開発

- 共同開発の入口は`docs/RAG_COLLABORATION.md`。RAG本体とプロンプト候補担当は別clone/branchで作業し、担当範囲をPR前に合意する。
- 本体担当は共通`docs/RAG_CLAUDE_HANDOFF.md`、プロンプト担当は`collaboration/rag-prompt/HANDOFF.md`を作業終了時に更新する。並行担当では担当別の記録を優先し、統合担当が共通引き継ぎへ集約する。
- 友人の候補は本番promptへ直接反映しない。凍結資料/未使用問題を保護し、有料評価と公開操作は明示承認の範囲で行う。

## 複数エージェントでの開発

- ルール・手順・タスク管理(`AGENTS.md`、`docs/`、GitHub Project)は全エージェントで共有し、正本を1か所に保つ。
- エージェント定義(`.claude/agents/`、`.codex/agents/`など)は各ツールの形式で持つ。役割の責務を変えるときは、使用中の全ツールの定義を同時に更新する。
- 同じファイルを複数のエージェントが同時に編集しない。並行作業は`git worktree`でブランチを分ける。
- レビューは実装したエージェントとは別のエージェント(可能なら別モデル・別ツール)で行う。
- エージェント間の引き継ぎは会話ではなく、`docs/`・GitHub Project・PRなど残る場所に書く。
