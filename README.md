# studiquo

iPad向けSwiftUI学習アプリ。授業資料（PDF）を見ながら手書きでノートを取り、暗記カード・文書・予定・AIトークで復習までをひとつのアプリで行えます。

アプリ（`studiquo/`）と、認証・AIプロキシ・友達機能・MCP連携を担うサーバー（`mcp-server/`、Cloudflare Workers）で構成されています。

## 主な機能
- **手書きノート**: Apple Pencilでの手書き（自作の描画エンジン、筆圧対応）
  - ペン先を止めると直線に、閉じたループを描くと円/楕円に自動補正
  - スクリブルでこすって消去、投げ縄（範囲選択）、手書きの文字認識
  - ページテンプレート、画像・図形などの要素の配置
- **PDF・資料の取り込み**: PDFを背景に展開して注釈、DOCX・画像・スキャン（書類スキャナー）・共有拡張（studiquoShare）からの取り込み。パスワード付きPDFにも対応
- **分割ワークスペース**: 左右・上下の2分割で、授業資料とノートを同時に表示。仕切りをドラッグしてサイズ変更でき、反対側にはノート・暗記カード・文書・簡易ブラウザなどを選べる。上部のタブバーで開いている項目を切り替え
- **暗記カード**: デッキの作成と学習モード
- **文書**: 見出し・表・コメント・変更履歴を持つ文書エディタ。共同編集に対応
- **カレンダー・学習記録**: 予定の管理と学習時間の記録
- **AI機能**: AIトーク、証明の添削、復習教材（解説と一問一答）の生成、間違えた問題の復習。数式は組版して表示
- **友達・グループ**: 友達追加（QR対応）、チャット、通報・ブロック
- **MCP連携**: ClaudeやChatGPTなどのAIアプリから、ノート・暗記カード・予定の参照や資料の作成ができる
- **書き出し・バックアップ**: 描いた内容込みのPDF書き出し、共有シート、自動バックアップとその復元
- **同期と保護**: SwiftDataとCloudKitによるAppleデバイス間の同期、ノートの暗号化・パスコード保護、Apple / Google / メール / Passkeyでのサインイン
- **プラン**: standard / plus / pro（RevenueCatによる課金）。プランごとにAIの利用上限が異なる

## セットアップ（このMacで実行する手順）
Xcode 26.6のiPadシミュレータ・実機でビルド・起動を確認済みです。最小のデプロイ先はiOS 17.0です。

1. **Xcodeをインストール**（App Store）。初回起動時にiOS Simulatorの追加コンポーネントも入れる。
2. **XcodeGenをインストール**（プロジェクトファイル生成用）
   ```bash
   brew install xcodegen
   ```
3. **プロジェクトを生成**
   ```bash
   git clone https://github.com/kohtaroh928/studiquo.git
   cd studiquo
   xcodegen generate
   ```
4. `studiquo.xcodeproj` をXcodeで開き、実行先を「iPad」のシミュレータ（またはお手持ちの実機）にして ▶ Run。

`studiquo.xcodeproj` はXcodeGenが`project.yml`から生成するため、Gitには含まれていません。`project.yml`を変更した場合は`xcodegen generate`を再実行し、Apple Sign InとCloudKitのCapabilitiesが残っていることを確認してください。

アプリとサーバーは独立して更新されるため、APIを変えるときは新旧バージョンの互換性を保ってください。

### サーバー（mcp-server）
```bash
cd mcp-server
npm install
npm test            # ユニットテスト
npm run typecheck   # 型チェック
npm run dev         # ローカル起動（wrangler dev）
```
APIキーなどの秘密情報はWorkerだけが持ち、アプリには入りません。設定・デプロイ・AIの利用上限は[mcp-server/README.md](mcp-server/README.md)を参照してください。

## ディレクトリ構成
```
studiquo/
  project.yml                # XcodeGenのプロジェクト定義（正本）
  studiquo/                  # iPadアプリ
    StudiquoApp.swift        # エントリーポイント
    Models/                  # SwiftDataモデル（Notebook, NotePage, FlashcardDeck など）
    Views/                   # SwiftUI画面（一覧、エディタ、分割ワークスペース、AIトークなど）
    Services/                # 認証・通信・AI・課金・入出力・暗号化・バックアップなどの非UI処理
    Ink/                     # 自作の手書き描画エンジン（PencilKit不使用）
    Assets.xcassets/
  studiquoShare/             # 共有拡張（他アプリからの取り込み）
  studiquoTests/             # ユニットテスト
  studiquoUITests/           # UIテスト
  mcp-server/                # Cloudflare Workers（API・MCP・認証・AIプロキシ・運営機能）
  security/                  # SAST・DASTなどのセキュリティ検査
  scripts/                   # 秘密情報スキャン、脆弱性監視
  docs/                      # 設計・運用・リリース関連の文書
```

## ドキュメント
- 全体像: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- データとマイグレーション: [docs/DATA_AND_MIGRATIONS.md](docs/DATA_AND_MIGRATIONS.md)
- セキュリティとプライバシー: [docs/SECURITY_AND_PRIVACY.md](docs/SECURITY_AND_PRIVACY.md)
- 運用手順・リリース: [docs/RUNBOOK.md](docs/RUNBOOK.md)、[docs/RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md)
- 開発の進め方（エージェントを含む）: [AGENTS.md](AGENTS.md)、[docs/DEVELOPMENT_WORKFLOW.md](docs/DEVELOPMENT_WORKFLOW.md)

残タスクと未解決の問題はGitHub Projectの「Studiquo タスク」(非公開)で管理しています。
