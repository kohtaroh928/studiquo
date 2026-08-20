# studiquo

iPad向けSwiftUI手書きノートアプリ。授業資料（PDF）を見ながら別のノートへ書き込めます。

## 実装済み機能
- Apple Pencilでの手書き（自作の描画エンジン、筆圧対応）
  - ペン先を止めると直線に、閉じたループを描くと円/楕円に自動補正
  - スクリブルでこすって消去
- PDFの読み込み（各ページを背景として展開し、その上に注釈可能）
- ノート管理（複数ノート・複数ページ、SwiftDataで自動保存）
- 暗記カード（作成・学習モード）
- 書き出し・共有（描いた内容込みでPDFとしてエクスポート、共有シート経由）
- アプリ内の左右・上下2分割ワークスペース
  - 片側に授業PDF、もう片側に白紙ノートを表示
  - 左右それぞれ独立してページ移動・書き込み・ズーム
  - 仕切りをドラッグして30:70〜70:30でサイズ変更
  - 反対側に既存ノート・暗記カード・簡易ブラウザを選択可能
  - 上部タブバーから開いているノート/暗記カード/Webを切り替え

## セットアップ（このMacで実行する手順）
Xcode 26.6のiPadシミュレータ・実機でビルド・起動を確認済みです。

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

`studiquo.xcodeproj` はXcodeGenが`project.yml`から生成するため、Gitには含まれていません。`project.yml`を変更した場合は`xcodegen generate`を再実行してください。

## ディレクトリ構成
```
studiquo/
  project.yml                # XcodeGenのプロジェクト定義
  studiquo/
    StudiquoApp.swift        # エントリーポイント
    Models/                  # SwiftDataモデル（Notebook, NotePage, FlashcardDeck など）
    Views/                   # SwiftUI画面（一覧、エディタ、分割ワークスペースなど）
    Services/                # PDF読み込み・書き出し・バックアップ処理
    Ink/                     # 自作の手書き描画エンジン（PencilKit不使用）
    Assets.xcassets/
```

## 次の実装候補
- 投げ縄（範囲選択）ツールをInkエンジンに実装
- フォルダ分け・タグ・検索の強化
- ページテンプレート（方眼・罫線など）の拡充
- PDFダークモード、PDF余白調整
