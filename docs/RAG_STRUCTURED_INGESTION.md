# 構造chunk・メタデータのWorker保存接続

2026-10-17。High変更として詳細開発手順・独立Planner・コード/安全レビューを適用する。作業ブランチcodex/rag-wip。remote migration/deployは含まない。

## 目的と受け入れ条件

Doclingが分割済みの本文と保護要素を、従来のpage.textから再分割せず索引へ保存する。認可済みD1のmetadataを検索結果の出典へ渡す。既存pages形式・旧DBの読み書きを維持する。

- 新入力はpayload.structure（version/documentNamespace/document）と各page.structured.records（text/metadata）。混在・不完全・要OCR/確認・未知要素を拒否し、validationは更新前に完了する。
- 許可kindはtext/paragraph/title/section_header/list_item/footnote/caption/table/formula。表はMarkdown全文とtable構造hashを保存する。表セル構造本体はlocal出力にのみ残る。図や未知kindを黙って落として登録しない。
- Python exporterは全資料の本文coverage/保護要素全件/未割当なしを確認してから最大5page、240KiBのprivate batchを作成する。送信や鍵読取は行わない。空page/図等がある文書は初版では全体拒否する。
- 本文hash/codepoint範囲長/page/namespace整合をサーバーでも検証する。metadataを認可判断に用いない。原要素全文を受信しないため、申告された座標/見出しの真正性は証明しない。
- 新migrationでrag_chunks.metadata_jsonだけを追加。文書共通metadataもこの列内に持たせ、既存削除経路と共に削除する。Vectorizeのmetadataはowner/source/folder/pageの最小情報を維持する。
- 新形式のみpageHashに正規化structure全体を含め、共通contextHashにもmode/文書情報をbind。形式・解析方式・metadataだけの変更も再登録する。embeddingHashは実Embedding入力だけをhashし、同一入力の既存vectorを再利用する。
- folder移動cloneでmetadataを保持。更新はlease別新chunkIDで、metadataのinplace更新を作らない。旧出典proofはchunkID消失/完了状態/context変更により再認可を通らない。
- 出典は認可済み隣接最大3chunkの位置を分けて投影し、要素bboxを引用文精密bboxと言わない。stored metadataが不正な場合は安全にreferenceを使わない。

## 脅威と障害

未知field/過大配列/非有限座標/偽hash/他ownerのID/別page参照を拒否する。namespaceはクライアント識別子でaccount/sourceの代わりにならない。既存認可、同意epoch、lease、vector cleanup journal、削除途中の拒否を保持する。

外部書込み失敗時は既存pending/cleanup経路を使用する。新metadataはD1本文と同じscope/寿命とし、ログには本文・metadataを出さない。新形式未対応DBは更新前にupgrade-requiredで停止。旧DBへのlegacy読み書きは追加列を参照しない。

## 段階公開・ロールバック

migrationはローカルSQLiteでのみ検証し、remoteへ適用しない。公開時はDB追加列→対応Worker→対応送信元の順。旧Workerへ戻す前に新形式送信を停止すること（旧コードは新fieldを無視し得る）。追加列を破壊的に削除せず残し、旧形式で再索引する場合は構造情報が無くなることを明示する。既存RAG/自動索引/AI承認flagは変更しない。

iPadでDoclingを自動実行する接続、PDF内の座標ジャンプUI、metadataでの追加filter/モデル変更、実ユーザー資料による品質比較は後続。API/保存接続のテスト成功を回答精度改善としない。


## 検証結果

- Worker全1,722件成功、失敗/skip0。最終logはprivate `/private/tmp/studiquo-structured-ingestion-final2-20261017.log`。新規metadata/citation15件には旧DB、metadata-onlyvector再利用、移動clone、source/account削除、別owner、更新中cancel、旧proof失効、壊れたstoredmetadata、HTTP400、100pageの20batch完了と共通context変更失効を含む。
- Python49件成功。新exporter6件で全coverage/保護要素/100page/要確認拒否/改変/Workerと同じtoken・heading上限を検証した。
- 実Docling合成2page（前工程でoffline抽出）→private exporter→Worker validator→ローカルSQLite→検索/出典metadataの接続を実行。8records（表2）を保存、出典metadataを確認。Embedding/rerankはfixtureで、外部AI/API/鍵は使用していない。実Cloudflareへの登録ではない。
- 独立Plannerは当初Python/Worker上限不一致のMediumと引用範囲のLowを発見。既存pinned regexでWorker相当token近似/ECMA whitespace、heading区切りを統一。元の句読点600個反例をexport前拒否し回帰追加。citationは`rangeScope: stored_chunk_not_excerpt`を追加。修正後独立Planner JS13/Python49、独立安全最終JS15/Python49成功、High/Medium残件なし。
- 凍結評価器のsource hash7件と完了した実API runの固定manifestが不変。新しい有料run・未使用20問の調整利用なし。

500tokenはWorker既存の近似値でモデルtokenizerの厳密計数ではない。Unicode propertyのruntime版差や本番D1/Vectorizeの遅延・障害、実ユーザー資料の検索品質は未評価。ExporterはCLI/API接続準備用で自動送信・iPad内Docling実行を追加していない。metadata追加による回答精度改善は未証明。

Projectの資料更新が必要: ARCHITECTURE.md / DATA_AND_MIGRATIONS.md / HYBRID_RAG.md（設計）。複製の置き場は未更新。
