# 実資料でのRAG検索評価

## 結果

2026-10-08、気象庁の公開教科書『総観気象学 基礎編【改訂版】』348物理PDFページを、固定した新しい30問で評価した。
根拠がある24問は、必要なすべての正解ページと返却context内の根拠anchorを取得した。根拠なし6問は出典なし。
**ただし比較4問のうち3問は、必要な記述がそろっていてもpartialと判定された。検索に必要な情報の取得と、比較の完全性の判定は別の結果である。**
1冊から選んだ小規模な問題群であり、製品全体の検索精度100%・回答精度100%・公開可能という意味ではない。

| 分類 | 問数 | 必要な全anchor取得 / 根拠なしの出典抑制 | 検索状態 |
|---|---:|---:|---|
| 直接質問 | 6 | 6/6 | grounded 6 |
| 言い換え | 8 | 8/8 | grounded 8 |
| 数値 | 6 | 6/6 | grounded 6 |
| 比較 | 4 | 4/4 | grounded 1、partial 3 |
| 同じ分野だが必要な詳細がない | 4 | 4/4（出典なし） | insufficient 4 |
| 無関係な質問 | 2 | 2/2（出典なし） | fallback 2 |

API/Embeddingの不正応答・総検索deadline付近の事例は品質の分母から除外する設計。この実行は30/30評価対象、実行失敗0、API 412回すべて成功だった。
構造化出典114件は、計測DBの所有者・資料・物理ページ・chunkの整合性をすべて確認した。

## 資料と固定方法

出典：気象庁監修、北畠尚子著『総観気象学 基礎編【改訂版】』。
[資料掲載ページ](https://www.jma.go.jp/jma/kishou/know/expert/index.html)、[PDF](https://www.jma.go.jp/jma/kishou/know/expert/pdf/textbook_synop_basic_revision_20250331.pdf)、[利用規約](https://www.jma.go.jp/jma/kishou/info/coment.html)。気象庁の公開資料を利用したStudiquoの評価であり、気象庁が作成・承認した評価ではない。
送信は抽出本文のみで、図・写真の画像は送信しない。教材の原文・質問・anchor・EmbeddingはGitや結果ログへ保存しない。
PDFKitのpage.stringと、文字層が空のページへのVisionを利用した。OCR対象2ページ（2・347）は空白であり、今回OCR品質は測定していない。
画像を目視したページでは数式の記号が抽出本文から欠ける現象があった。数式の構造保持は今回の検索合格と別の未解決事項である。

30問、24 positive / 6 negativeを検索実行前に固定。独立担当が代替正解ページと44 anchorを本文に照合した。
物理PDFページを使用し、導入以降の印刷ページ番号とのずれは6ページ。
全問題を調整に使った過去の合成fixtureから流用せず、この教材から新規に作成した。重み・検索閾値・productionコードは変更していない。

- PDF SHA-256: `f4ff9a30ab3e6e5aa0eefba48c17eac9d9d9ef6ed5cd0483d2931f7a6b58eaa4`
- 抽出本文 SHA-256: `d109fd41da52b70b37d967e0ee13465a74546d0aa057179479b3b89044e02574`
- 固定manifest SHA-256: `11f5c09ab227a0a334ad008ec341f8eb1f1e8fde2c6c6b24a6984b31011d043b`

## 実環境と代替の区別

実Workers AI RESTで `@cf/baai/bge-m3` / `@cf/baai/bge-reranker-base` を呼び、本番のindexSource / retrieveを再利用した。
D1相当はローカルSQLite FTS5、Vectorize相当はメモリ上の厳密cosine。実Vectorizeの近似検索、D1 binding、staging Worker、iPad経路、Geminiの最終回答は測っていない。
raw RRFは本番関数でTop120を記録し、実際の関連性・多様性条件で絞ったTop15 Rerank候補と区別する。本文一致で候補が複数ある場合は曖昧さを残す。
正解ページの一致と、最終neighbor展開・本文制限後のcontextにanchorが残るかを別々に測る。anchor一致は意味の一般的な含意・事実の真偽の保証ではない。

## 登録・応答時間・使用量

- 348ページを70バッチで登録（5ページ単位、最後3ページ）。空白2ページを除くEmbedding 346回。
- 同じsourceHashで全ページを再登録し、追加Embeddingは0回。
- 検索Embedding 38回、Rerank 28回。合計412 API呼び出し、319.39 Neurons。
- 検索時間中央値918.5ms、最大2,438ms。RESTの往復を含み、iPadの体感時間やGemini回答生成時間は含まない。
- jma-04 / 13のRerankは2秒制限を超え、既存の順位へfallbackした。必要な根拠は取得できた。
- deadline後の遅延APIも終了を待って使用量を集計し、ユーザーに返す検索時間と待機時間を分離した。

## 残っている問題

1. jma-21 / 23 / 24は必要な根拠を取得してもpartial。比較対象の語句と本文のcoverage判定のずれが考えられる。検索の候補漏れと混同せず、複合質問の主題判定の回帰事例にする。
2. PDFの数式記号が文字層から欠ける。通常の文章の取得率を数式の正確性へ拡張しない。
3. 今回は1冊の公開教材。手元の教科書、講義資料、編集可能Notebook、手書き、非空白のOCR、異なる科目を追加する必要がある。
4. 実Vectorize/D1とiPadの検証は別工程。今回のcosine検索はVectorizeの近似検索の品質を保証しない。
5. Geminiへ渡った後の実教材の回答正確性は未測定。

## ツールと検証

新規：`real-material-evaluate.mjs`、`extract-material-pdf.swift`、`rag-real-material-evaluation.test.js`、本報告、`RAG_REAL_MATERIAL_RESULTS.json`。
評価ツール14/14、全Worker732/732成功。独立セキュリティ担当の12/12再実行と、最終追加の別視点レビューも成功。本文・質問・認証情報の出力なし。
抽出ツールは同じ348ページで再実行し、抽出ファイルhashの一致を確認した。出力はexclusive作成・初期0600で、既存ファイルの保持とsymlink拒否を検証した。保存ディレクトリは0700。今回はproduction/iOSを変更せず、iOS suiteは再実行していない。
独立担当がgoldenを実行前に、集計を実行後に確認した。未解決のコード上の重大指摘なし。
Cloudflareの既存認証を更新して利用したが、deploy・migration・binding変更・本番データ操作は行っていない。RAG_ENABLED=falseを維持。

## 再現とプライバシー

入力PDF、抽出JSON、質問とanchorを含むmanifestは `/private/tmp/studiquo-rag-real-materials-v1` にのみ保存。exact再現にはこのprivate manifestが必要で、Gitの集計JSONだけからは再現できない。一時領域を清掃すると入力が失われる。
今後の私有教材は、指定された利用可能資料だけを処理する。実AI評価はCloudflareへの本文送信を伴うため、runnerは明示的opt-inを必須にする。API error本文は保存せず、呼び出し500回、45秒、response 8MiBに制限する。

```sh
# 書き込み先は私有ディレクトリ内の新しいファイル。
mkdir -m 700 /private/tmp/evaluation
# 既存抽出JSONを上書きしない。
node mcp-server/scripts/rag-quality/extract-material-pdf.mjs /path/to/authorized.pdf /private/tmp/evaluation/pages.json
# manifestにはsources、questions、正解ページ候補とanchorを実行前に固定する。
STUDIQUO_RAG_REAL_MATERIAL_REMOTE=true node mcp-server/scripts/rag-quality/real-material-evaluate.mjs /private/tmp/evaluation/manifest.json /private/tmp/evaluation/metrics.json
```

CLOUDFLARE_ACCOUNT_IDと既存OAuth/API tokenはローカルで指定する。認証値をコマンド引数、結果、Gitへ書かない。
私有教材の評価では、結果ファイルをGitへ追加する前に本文・質問・識別情報がないことを確認する。本評価の結果はpublic資料の非本文メトリクスのみ。
