# iPadアプリ(`studiquo/`・`studiquoShare/`)セキュリティ監査(2026-11-02)

対象: `main` の `86c85eb` 時点の `studiquo/` および `studiquoShare/`。
方法は、領域別に分けた3つの読み取り専用レビュー(① 外部入力・IPC・URLスキーム・共有拡張・外部ファイル・パーサー境界 / ② 認証・Keychain・保護ノート暗号化・バックアップ・退会消去・課金 / ③ AI・RAG・MCP連携・チャット・通知・診断ログ・Semgrep未解析ファイル)。既存の [THREAT_MODEL.md](THREAT_MODEL.md) と [SECURITY_VERIFICATION.md](SECURITY_VERIFICATION.md) に載っている既知事項は重ねていない。

## この監査の限界

- コードの読み取りと単体テストが根拠。iPad実機上のファイル保護属性(`NSFileProtectionKey`)やCloudKit同期削除の実機確認は別途行う。
- Critical は無し。**High 6件、Medium 6件、Low 2件**。

## 指摘一覧(修正優先度順)

| ID | 優先度 | 深刻度 | 内容 | 場所 | 状況 |
|---|---|---|---|---|---|
| CHAT-1 | P0 | High | フレンド/グループチャットの添付メタデータ(`FriendMessageAttachment`)が送信者のローカルフルパス(`sourcePath`)を送信・信頼しており、細工メッセージによる任意ローカルファイル削除・QuickLook表示・キャッシュ保存時パストラバーサル・保護ノート添付が可能 | `ProfileAndFriendsView.swift` `messageLine`, `FriendMessageParts.init`, `deleteLocalAttachmentFiles` / `ContentView.swift` `openFriendAttachment`, `downloadAndPreviewFriendAttachment`, `friendMessageAttachmentOptions` / `NoteEditorView.swift` | 修正・単体テスト済(`antigravity/ios-security-audit`) |
| LOCK-1 | P0 | High | 2画面分割の副ペイン(`secondaryNotebook`)やタブ切替(`primaryOverrideNotebook`)で開いた保護ノートが再ロックされず、平文のままSwiftData・CloudKitに永続化する。またバックグラウンド復帰時に`NotebookLockGate`の認証状態がリセットされず、再認証バイパスと復帰後加筆の消失が起きる | `NoteEditorView.swift` `scenePhase`, `onDisappear`, `sealNotebooksNoLongerDisplayed` / `ProtectedNotebookView.swift` `NotebookLockState`, `NotebookLockGate` | 修正・単体テスト済(`antigravity/ios-security-audit`) |
| LOCK-2 | P0 | High | ロック画面表示中に上部ツールバーからページ追加/削除を実行でき、`pages.count`不一致で保護ノートが永久に復号不能になる。またMCPスナップショット(`makeMCPSnapshotData`)・ノート複製(`duplicate`)・AI/チャット添付候補・カバー画像・自動バックアップ・AIチャット文脈(`aiChatNoteContext`)・チャット添付一時プレビュー(`temporaryChatMaterialView`)で保護ノートやパスワード付きPDF(`hasLockedPDFToUnlock`)の除外が漏れている | `NoteEditorView.swift` `paneShowsNote`, `aiChatNoteContext`, `temporaryMaterial` / `NotebookEncryptionService.swift` `unlock` / `ContentView.swift` `makeMCPSnapshotData`, `duplicate` / `AIAppAttachmentCatalog.swift` / `NotebookCover.swift` / `NotebookBackupService.swift` | 修正・単体テスト済(`antigravity/ios-security-audit`) |
| AUTH-1 | P1 | High | ログアウト時にKeychainの`oauth-identity`・`passkey-identity`や`FriendStore`・プロフィール`UserDefaults`が消去されず、別アカウントでのログイン時にメールアドレス・チャット履歴が混同する | `AuthenticationStore.swift` `logout`, `persistOAuthIdentity`, `loginWithPasskey` / `ProfileAndFriendsView.swift` `FriendStore` | 修正・単体テスト済(`antigravity/ios-security-audit`) |
| DOC-1 | P1 | High | `DocumentBody.decode`が`NSKeyedUnarchiver`で`requiresSecureCoding = false`を使用しており、細工されたアーカイブデータで任意の`NSCoding`クラスがインスタンス化されうる | `TextDocumentView.swift` `DocumentBody.decode` | 修正・単体テスト済(`antigravity/ios-security-audit`) |
| MATH-1 | P1 | High | `MathTextFormatter.TeXParser`の`\def`/`\newcommand`展開に総ノード数上限が無く、約200文字のネストマクロ(深さ14 < 上限60)で指数関数的展開(Billion Laughs)によるOOMクラッシュ・永続DoSが起きる | `MathTextFormatter.swift` `TeXParser.parseCommand`, `parseMacroDefinition` | 修正・単体テスト済(`antigravity/ios-security-audit`) |
| LOCK-3 | P2 | Medium | グローバルUndo履歴(`NoteActionHistory.shared`・`DrawingHistoryStore.shared`)と画像キャッシュ(`NoteImageCache.shared`)に保護ノートの平文スナップショットが残り、別ノートでのUndoでロック済みノートが書き換えられる | `NoteActionHistory.swift` / `NoteEditorView.swift` / `NoteImagePipeline.swift` | 修正・単体テスト済(`antigravity/ios-security-audit`) |
| LOCK-4 | P2 | Medium | `NotebookEncryptionService`がAI添削フィールド(`proofQuestion`, `proofModelAnswer`, `proofRubricData`, `proofReviewData`)を暗号化・消去対象から除外しており、手書き解答の抜粋等が平文で残る | `NotebookEncryptionService.swift` `EncryptedContent` | 修正・単体テスト済(`antigravity/ios-security-audit`) |
| ERASE-1 | P2 | Medium | 退会・ログアウト時にKeychain内の大学/Googleカレンダー秘密URL、GoogleSignIn OAuthトークン、`LibraryLedger.json`、メモリ上の`ExternalFileBookmarkStore`が残存する | `AccountFileEraser.swift` / `ExternalFileBookmarkStore.swift` / `CalendarHomeView.swift` / `AuthenticationStore.swift` | 修正・単体テスト済(`antigravity/ios-security-audit`) |
| SHARE-1 | P2 | Medium | 共有拡張・`SharedInbox`がサイズ・シンボリックリンク検証前にApp Groupへフルコピーする。非PDFの上限超過時に成功と誤判定する | `SharedInbox.swift` / `ContentView.swift` `runSharedImport` | 修正・単体テスト済(`antigravity/ios-security-audit`) |
| MCP-1 | P2 | Medium | `pullMCPInbox` / `applyMCPActions`にアクション数・ページ数・カード枚数・文字数の上限とIDパス検証が無い。また`DocxZip.inflate`がヘッダ申告サイズ(最大100MB)を無条件先行確保し、未圧縮エントリの単一上限チェックが無い | `ContentView.swift` `applyMCPActions`, `disconnectMCP`, `pullMCPInbox` / `DocxZip.swift` `readLocalEntry`, `inflate` | 修正・単体テスト済(`antigravity/ios-security-audit`) |
| LINK-1 | P2 | Medium | `DocxReader`および`TextDocumentView.applyLink`がURLスキームを検証せず`studiquo://`等のカスタムスキームを文書リンクに設定できる。またパスワード解除PDF(`PDFPasswordService`)にページ数上限とData Protection属性が明示されていない | `DocxReader.swift` / `TextDocumentView.swift` / `PDFPasswordService.swift` | 修正・単体テスト済(`antigravity/ios-security-audit`) |
| CHAT-2 | P3 | Low | `FriendChatService`のURLパス構築でのID検証、受信アバター画像のサイズ上限検証、`AIReviewService.considerForReview`の非同期待機後のパーティション一致再確認 | `FriendChatService.swift` / `AIReviewService.swift` | 修正・単体テスト済(`antigravity/ios-security-audit`) |
| AUTH-2 | P3 | Low | パスキー設定済み端末フラグ(`knowsPasskeyOnThisDevice`)の扱い | `AuthenticationStore.swift` | 既存仕様(`AuthenticationStoreTests`でログアウト時は保持し退会・パスキー全削除時に消去)を確認し維持 |

## 検証・独立レビュー結果(2026-11-02)

- **単体テスト**: `IOSSecurityAuditFixesTests` (新規9テスト)および関連18テストスイート計256件を実行し全件通過(`xcodebuild test -scheme studiquo`)。
- **独立レビュー**: 読み取り専用サブエージェントによる独立レビューを実施し、ペイン切替時の旧保護ノート再封印(`sealNotebooksNoLongerDisplayed`)・チャット添付ノート一時プレビューのゲート通過・未解錠ノートのAI文脈除外・`DrawingHistoryStore`消去の追加指摘もすべて反映済。

## 問題なしと確認した範囲(Semgrep未解析4ファイルを含む)

- **RAG索引・同期**(`RAGIndexingService.swift`, `RAGLibrarySyncService.swift`, `RAGStructuredDocument.swift`, `RAGStructuredAttachment.swift`): ロック中・暗号化ページ・パスワード付きPDF・ゴミ箱の4条件除外、トークンSHA-256によるパーティション分離、チャンク・文字数上限が徹底されている。
- **AI応答リンク・出典表示・SSEストリーム**(`AILinkPolicy.swift`, `RAGCitationMetadata.swift`, `BoundedAIStreamLines.swift`, `AIProvider.swift`): `http`/`https`限定・プライベートIP拒否、バウンディングボックスの`isFinite`と`[0,1]`クランプ、1行256KB上限、AI送信同意・年齢区分ヘッダ強制を確認。
- **課金状態管理**(`SubscriptionStore.swift`): アカウント切替時の即時`.free`リセットと非同期完了時の`lastSyncedUserID`照合を確認。
- **WebView・QR・外部ファイル分割**(`NoteEditorView.swift` `WebBrowserModel`, `BrowserDataEraser.swift`, `QRScanRoutingPolicy.swift`, `ExternalFilePanePolicy.swift`, `ScopedFileAccess.swift`): 非永続データストア、JSブリッジなし、招待確認ダイアログ必須、`ScopedFileAccess`の`NSLock`による確実な解放を確認。
- **診断・問題報告**(`ErrorReportService.swift`, `DiagnosticReportBuilder.swift`, `IssueReportService.swift`, `UsageEventService.swift`): 既定OFF、Bearerトークン・メール・パスの正規表現マスクを確認。
- **Semgrep PartialParsing対象4ファイル**:
  - `AppNotificationService.swift`: 問題なし(トークン平文ログなし、復習通知の問題文非表示設定、通知タップからの保護ノート直接解錠なし)。
  - `InkCanvasView.swift`: 問題なし(全3,124行確認、純粋な描画処理のみ)。
  - `StudyTimeTracker.swift`: 問題なし(全143行確認、学習時刻と秒数のみ)。
  - `ProfileAndFriendsView.swift`: 上記 `CHAT-1`・`AUTH-1` を検出。
