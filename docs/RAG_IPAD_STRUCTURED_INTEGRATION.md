# iPadのDocling構造索引・出典接続

2026-10-17。codex/rag-wipのローカル実装。公開・remote migration・実資料品質評価とは区別する。

## 実装と受け入れ条件

- 原PDFとprepared packageを同時選択して、新しいNotebookへ取り込む。原bytesのSHA256、Docling namespace、全page/record/metadataのstrict検証を行い、タイトルやページ数だけでは既存資料に結び付けない。JSON重複key、深さ・token数・容量も制限する。
- 取り込みは最大100page、各辺1..4096points、各page4MP、PNG総量128MiB。原PDFは選択中のメモリだけで、今回新たに原PDFを永続保存しない。ファイル選択だけでは外部送信しない。
- package/fingerprint/originalPDF hashはSwiftData optional属性に保存し、ロック時には既存暗号化payloadに封入して平文属性を消去する。旧暗号文は互換。本文・画像・手書きの変更でpackageが失効し、その後は現在の端末抽出経路へ戻る。
- manual/managed索引とも既存の構造batchを再分割せず送信する。WorkerのstructuredIngestVersion=1を確認する。旧Workerやmetadata列未導入の環境へ構造データを黙って送らない。account/endpoint/同意/lock/削除/fingerprintの再確認で処理中の変化を止める。
- 出典metadataを受信・会話保存・再読込できる。不正metadataだけを捨て、旧page/source出典を保つ。引用buttonの認可と遷移先は従来のsource/page確認を使用する。位置情報は補助表示であり、bbox精密ジャンプは未実装。
- 通常/画像のAI streamingをbyte単位の有限line readerへ接続。line512KiB、error body64KiB、strict UTF8、キャンセル時URLSession task停止。本文を含むerrorはログへ記録しない。

## 検証

- 署名付きiPad simulator関連7suite: 98件成功、失敗0。stream12、encryption5、citation13、client28、library22、attachment7、document11。
- endpoint変更回帰を追加した最終関連再検証: client28 + attachment8 = 36件成功、失敗0。前項と重複するので134件とは数えない。現在の選択suite内のunique testは99件（99件を一括再実行したわけではない）。
- Worker全体: 1723件成功、失敗/skip0。disabled statusの旧応答shapeを維持した。
- 既存Docling/Python49件成功。実合成2pageのDocling→prepared exporter→Swift原PDF hash照合も成功。実利用者資料は使用していない。
- host補助検証: citation/stream25 XCTest成功、structured document11相当のassertion harness成功（host XCTestとしては数えない）。

最初のunsigned iOS runはKeychain依存15件失敗。署名付きへ変更後、既存のin-memory chat persistence test1件がCoreData接続例外で停止した。CloudKit自動選択を避け、該当testだけcloudKitDatabase:.noneを明示し、既存assertionを維持した。単独再現→修正後単独成功→上記98件成功を確認。Notebook新属性が直接原因だったとは確定していない。

Planner/Code/Securityの独立確認で、旧Worker capability、同意表示、描画辺上限、画像fingerprint、await中編集、endpoint変更の問題を修正した。最終時点の未解決High/Medium指摘なし。テスト成功は回答精度向上の証明ではない。

## 公開順と停止

migration0009を含むWorkerの検証・反映後に新iPadを有効化する。RAG flagsはfalse維持。旧入力互換を保ち、列なしの場合は新構造受付を停止する。アプリのpackageは編集で失効するので、強制的に古いpackageを再送しない。Notebook optional属性の既存実store/iCloud移行・ロック実機検証は公開前に必要。DesktopのProject資料複製は未変更。

## 残る工程

原PDFの自動Docling実行サーバー・別同意・admission・取消/削除連携・iPad接続、実encoderの意味分割、日本語/OCR/図/数式と100page品質・性能、精密位置遷移、実機のfile picker/総合UI/永続store移行、実Cloudflare統合、運用費用/依存監査。自動解析先はCloudflareを暫定前提にローカル設計を継続し、配備・追加購入は含めない。自動スケジュールはPAUSED。
