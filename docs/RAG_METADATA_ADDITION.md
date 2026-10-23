# Docling分割結果のメタデータ追加

日付: 2026-10-16。対象は開発用local Docling adapter。Worker/iPadの索引入力・保存・検索・出典UIへの接続は後続工程。

## 目的と受け入れ条件

分割した本文や保護した表・図・式が、どのPDFのどの要素から来たかを追跡できるようにする。本文hashと位置・解析方式などのmetadata hashを分け、本文が同じでも位置や確認状態が変わったことを検知する。メタデータは資料の正しさやアクセス権限を保証しない。

- 既存本文・chunkId・原文範囲・semantic unit bindingを維持する。
- parser名/版/profile、PDF digest、分割方式を文書共通情報として保持する。
- 各recordに種類、要素参照、物理ページ、要素由来のbbox/座標系、原文範囲、明示された関係、確認状態を保持する。
- 見出しは明示された親の連鎖だけを使用する。近接や本文から推定しない。参照欠落・循環・未確認を明示する。
- 未割当要素にページ番号を捏造しない。空ページや要確認状態を落とさない。
- 不正入力は出力ファイル作成前に拒否する。既存出力は上書きせず、パスや本文を失敗ログへ出さない。
- 合成資料による位置対応・metadata変更検出を検証する。形式テストを検索品質の改善とは扱わない。

## 設計上の区別

`documentNamespace`はPDF digestとparser情報を基にするlocal識別子。既存の要素ID/chunkIdと組み合わせて使用する。同一本文の別PDFを区別できるが、WorkerのaccountKey/sourceIdや認可とは別である。

`provenanceScope: element`のbboxは元要素全体の位置である。長文を分割したchunkの文字だけを囲む精密なbboxとは扱わない。Unicode code pointで示すchunk原文範囲と、Doclingが返すcharspanの意味を混同しない。

`textSha256`は既存の本文/semantic対応に使用する。別の`metadataSha256`は解析方式・位置・関係・確認状態を含むmetadataの変更検出用。改変検出用digestは署名や認可ではなく、信頼できない相手が再計算できる。

新たにパス・ファイル名・作成者・ユーザー情報・日時を収集しない。ただし見出し・参照・hashも機微情報になりうるため、元の資料と同じprivateファイル内で扱う。

## 接続時の残件

構造chunksをWorkerが再分割せず受け取る契約、D1での保存、索引世代・metadata更新・移動・削除との整合、検索後の認可確認、引用への安全な受け渡しが必要。Vectorizeにはルーティング用の最小情報を残し、豊富なmetadataの保存先と信頼元は別途設計する。旧アプリ互換・同意・データ削除を含む独立レビューの後に接続する。

既存のpages配列ではmetadataが渡らない。今回のlocal追加だけで本番の検索や引用が改善したとはしない。ロールバックは新しいmetadata出力の利用を停止すること。サーバーmigration・公開設定変更は伴わない。

## 実装結果（2026-10-17）

`tools/docling/metadata.py`のpure `add_metadata(envelope, pages)`を`--chunks-output`へ接続した。共通の`documentMetadata`、`metadataVersion: 1`、`documentNamespace`、`metadataSha256`を追加する。各本文chunk・保護要素・未割当要素の`metadata`にはlocalId、種類、原要素IDとその由来、pageNumbers、provenance、coordinateState、headingPath、contextRefs、review、原文範囲と本文digestを保持する。表は構造のdigestも保持する。

見出しpathはroot→leaf、stateはexplicit/partial/unknown、理由はcomplete/missing_parent/cycle/ancestry_limit/no_explicit_heading。明示ancestryは64段で停止する。座標系がTOPLEFT/BOTTOMLEFTと確認できた場合のみknownとし、座標の単位やページサイズを推定しない。未割当要素は常に要確認。元のschemaVersion/本文/chunkId/semantic bindingを変更せず、新metadataVersionを別管理する。

入力各32MiB、metadata 16MiB、総record 20,000、provenance/refs各100,000、深さ64などで制限する。recordへの付与ごとに累積metadata byte予算を確認し、繰り返し複製でメモリが膨らみ続けることを防ぐ。`verify_metadata`はmetadata digestの整合だけを確認する。本文照合や認可は別で、digestを再計算する相手への改変耐性はない。

## 検証

- Python43件成功。既存34件とmetadata9件。日本語・Unicode範囲、元入力/本文/IDs不変、位置/確認状態だけの変更検知、別PDF/parser namespace、明示見出しと循環、未割当・空ページ、表構造、改変検知、不正入力と累積サイズ制限を確認した。
- 実Docling合成2ページのoffline smoke成功。本文4chunk、保護4要素（表2）、metadata整合、座標系known、private0600を確認。実ユーザーPDFや外部APIは使用していない。
- 独立コードレビューでも43件成功、未解決High/Mediumなし。複製増幅のMediumと巨大整数入力での例外のLowを修正して回帰を追加。Workerソース変更はなく、Worker全テストの再実行は対象外。前工程の1,707成功を今回の結果としない。

保存先: private `/private/tmp/studiquo-metadata-smoke-20261017-01/`、本文なしsmoke結果 `/private/tmp/studiquo-metadata-smoke-20261017-01.log`。学習資料はrepositoryへ保存していない。

DB/検索/出典への接続は未実装。新有料評価、モデル追加取得、deploy、migration適用、push、mergeなし。自動実行はPAUSED維持。Projectの資料更新が必要: [設計] HYBRID_RAG.md。複製置き場の変更なし。
