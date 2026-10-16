# UIデザイントークン案(静かな集中系・ミニマル)

状態: 提案(未実装)。承認後に `Theme` として実装し、画面を順に置き換える。

## 方針

- 長時間の学習で目が疲れず、ノート・PDF・手書きの内容が主役になる見た目にする。
- アクセント色は1色だけ。意味を持たない装飾の色は使わない。
- 面の区別は影ではなく、背景色の差と細い境界線で行う。
- 操作の作法(ナビゲーション、シート、スワイプ)はiOS標準のままにする。
- ライト/ダークの両方、Dynamic Type、コントラストを必須とする。

## 1. 色(セマンティック名で持つ。画面側は名前だけを使う)

現状のアクセント `Color(red: 0.16, green: 0.33, blue: 0.63)`(`StudiquoApp.swift:280`)は #2954A1 に当たる。これを維持する。

| トークン | ライト | ダーク | 用途 |
|---|---|---|---|
| canvas | #F7F7F8 | #101113 | 画面の背景 |
| surface | #FFFFFF | #1A1B1E | カード、リスト行、シート |
| surfaceSunken | #EFEFF1 | #0B0B0C | 入力欄、凹んだ面 |
| line | #E2E3E6 | #2A2B2F | 境界線(0.5〜1pt) |
| textPrimary | #1B1C1F | #ECEDEF | 本文、見出し |
| textSecondary | #5F6168 | #A1A3A9 | 補足 |
| textTertiary | #8E9096 | #6E7077 | 重要でない注記のみ(コントラストが低い) |
| accent | #2954A1 | #7FA2E6 | ボタン、選択、リンク |
| accentSoft | #E6ECF7 | #1D2A44 | 選択中の背景 |
| danger | #C23A32 | #F07068 | 削除、エラー |
| success | #2E7D4F | #6CC590 | 成功 |
| warning | #B26A00 | #E8A33D | 注意 |

- ダークのアクセントは明るくして、暗い背景でのコントラストを確保する。
- 現状の `Color.indigo`、`Color.purple`、`Color.orange` などの装飾的な使い方は、意味のあるもの(状態色)以外は accent か textSecondary にまとめる。
- 手書きのペン色、ノート表紙の色はユーザーが選ぶ内容なので、このトークンの対象外にする。

## 2. 文字

- 書体はSF(システム)。文書表示のserifは据え置く。
- すべて `Font.TextStyle` 基準にして、Dynamic Typeに追従させる。

| トークン | 基準 | 用途 |
|---|---|---|
| titleLarge | .title2 + semibold | 画面タイトル |
| title | .title3 + semibold | セクション見出し |
| headline | .headline | カードの題名 |
| body | .body | 本文 |
| bodyStrong | .body + semibold | 強調 |
| label | .subheadline | リスト行、ボタン |
| caption | .caption | 補足 |
| numeric | .caption/.subheadline + monospacedDigit | 数値、日付 |

- 現状は `.caption` 82回、`.subheadline` 50回、`.headline` 43回が中心なので、ほぼ上の表に対応する。`.font(.system(size: 9...))` などの固定サイズは個別に見直す。
- 見出しの太さは semibold 以下に統一し、bold の乱用をやめる。

## 3. 余白(4pt基準)

`xs 4` / `sm 8` / `md 12` / `lg 16` / `xl 24` / `xxl 32`。画面の左右余白は lg(16)。

## 4. 角丸(現状10種類以上 → 4段階)

| トークン | 値 | 現状の対応 |
|---|---|---|
| radiusS | 6 | 3、6、8 |
| radiusM | 10 | 10、12、14 |
| radiusL | 16 | 16、18、20 |
| radiusXL | 24 | 24(シート、大きなカード) |

- すべて `.continuous` の角丸にする。
- 置き換えは近い段階に丸める。見た目が大きく変わる箇所は個別に確認する。

## 5. 面と影

- 通常のカード: surface + line(0.5pt)。影は付けない。
- 浮いているもの(ポップアップ、フローティングのツールバー)だけ、弱い影(blur 12 / y 4 / 不透明度 0.08)と `.regularMaterial` を許可する。
- 現状の `.shadow` 19回、`.regularMaterial` 28回は、この基準で見直す。

## 6. アイコン

- SF Symbols を使い、太さは regular、単色(`.monochrome`)で統一する。色は textSecondary か accent。
- 現状のSF Symbols参照は約160か所。まず太さと色だけをそろえる。

## 7. 動き

- 標準は 0.2秒の ease-out。大きな画面遷移は 0.3秒。
- 「視差」「バウンド」などの派手な動きは使わない。
- `accessibilityReduceMotion` が有効なときは、フェードのみにする。

## 8. 共通部品(トークンの次に作る)

1. `PrimaryButtonStyle` / `SecondaryButtonStyle` / `QuietButtonStyle`(`.plain` 106回の置き換え先)
2. `CardModifier`(surface + line + radiusM)
3. `ListRow`(アイコン、題名、補足、右側の操作)
4. `SectionHeader`、`EmptyState`
5. 入力欄のスタイル(surfaceSunken)

## 実装の置き場(案)

`studiquo/Views/DesignSystem/` に `Theme.swift`(色・文字・余白・角丸)、`Components.swift`(共通部品)を置く。色は Asset Catalog の色セット(ライト/ダーク)で持ち、`Color("canvas")` のようにせず、`Theme.Color.canvas` の型付きアクセサ経由で使う。

## 置き換えの順序(案)

1. Theme と共通部品を追加(見た目はまだ変えない)
2. アクセントと背景をトークンに切り替える(全画面に効く)
3. ホーム(`ContentView`)→ 一覧・フラッシュカード・AI → ノート編集 → プロフィール・フレンド → 設定
4. 画面分割表示、ダークモード、Dynamic Type、VoiceOver を各段階で確認する

## 未決の点

- 色の値は案。実機のiPadで、ライト/ダークとも長時間表示した印象を見てから確定する。
- ノート編集画面のツールバーや手書きのパレットを、どこまでトークンに合わせるか。
- アプリ名・アイコンの色味と、アクセント色(#2954A1)を揃えるか。
