# iPad手書きノートアプリ（試作）

授業資料を見ながら別のノートへ書ける、iPad向けSwiftUIノートアプリのMVPです。公開前に独自の製品名へ変更します。

## 実装済み機能
- Apple Pencilでの手書き（PencilKit、筆圧対応、ツールピッカー）
- PDFの読み込み（各ページを背景として展開し、その上に注釈可能）
- ノート管理（複数ノート・複数ページ、SwiftDataで自動保存）
- 書き出し・共有（描いた内容込みでPDFとしてエクスポート、共有シート経由）
- アプリ内の左右・上下2分割ワークスペース
  - 片側に授業PDF、もう片側に白紙ノートを表示
  - 左右それぞれ独立してページ移動・書き込み
  - 仕切りをドラッグして30:70〜70:30でサイズ変更
  - 反対側に既存ノートを選択、または白紙ノートを即時作成

## セットアップ（このMacで実行する手順）
Xcode 26.6のiPadシミュレータでビルド・起動を確認済みです。

1. **Xcodeをインストール**（App Store）。初回起動時にiOS Simulatorの追加コンポーネントも入れる。
2. **XcodeGenをインストール**（プロジェクトファイル生成用）
   ```bash
   brew install xcodegen
   ```
3. **プロジェクトを生成**
   ```bash
   cd ~/GoodNotesFree
   xcodegen generate
   ```
4. `GoodNotesFree.xcodeproj` をXcodeで開き、実行先を「iPad」のシミュレータ（またはお手持ちの実機）にして ▶ Run。

## ディレクトリ構成
```
GoodNotesFree/
  project.yml                # XcodeGenのプロジェクト定義
  GoodNotesFree/
    GoodNotesFreeApp.swift   # エントリーポイント
    Models/                  # SwiftDataモデル（Notebook, NotePage）
    Views/                   # SwiftUI画面（一覧、エディタ、手書きキャンバス）
    Services/                # PDF読み込み・書き出し処理
    Assets.xcassets/
```

## 次の実装候補
- レイヤー機能、図形認識、テキストボックス
- フォルダ分け・タグ・検索
- 消しゴム種類の切り替えUIカスタマイズ
- ページテンプレート（方眼・罫線など）
- PDFダークモード、PDF余白、手書き補正
