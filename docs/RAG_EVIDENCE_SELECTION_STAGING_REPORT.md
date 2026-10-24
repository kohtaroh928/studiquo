# RAG修正後の実Cloudflare・Gemini確認（2026-10-10）

`.worktrees/rag-wip` / `codex/rag-wip`で実装したtopic制約とevidence selectionを、ユーザーの依頼に基づきstagingへ配信・一時有効化して確認した。本番は変更していない。結論は**今回の合成検証の期待動作は成功**。実資料一般の精度、本番公開の承認ではない。

## 実モデルの結果

実Cloudflare Workers AIの`@cf/baai/bge-m3`（1024 dimensions）と`@cf/baai/bge-reranker-base`、D1 FTS・Vectorize、公開Worker `/api/ai/chat`→Geminiを使用。公開チャット11問と、実装関数・削除等を含む84/84チェックが成功。独立レビュアーも合成原文と11回答を照合し、明らかな不一致なし。

| 質問ケース | 状態 | 出典ページ | stream完了まで |
| --- | --- | --- | --- |
| detail-price-model | grounded | 6, 1 | 4.735秒 |
| detail-current-page | grounded | 6 | 2.275秒 |
| detail-duplicate | grounded | 1 | 2.358秒 |
| library | grounded | 1 | 3.092秒 |
| folder-ocr | grounded | 5 | 2.347秒 |
| notebook-ocr | grounded | 7, 10 | 1.987秒 |
| current-page | grounded | 11 | 1.936秒 |
| comparison | grounded | 3, 5, 1, 2, 4 | 2.305秒 |
| compound | grounded | 3, 5, 2, 1, 4 | 2.731秒 |
| wrong-folder | fallback | なし | 1.553秒 |
| other-owner | grounded | 1 | 2.930秒 |

11問の応答時間は中央値2.347秒、範囲1.553〜4.735秒。少数の短い合成質問であり、本番p95/SLAではない。

- **型番・価格・条件:** 型番ABC123と価格100円を、ページ1と6の構造化出典とともに回答。「送料別途」「法人向け」「店頭受取専用」も保持。current pageでは6ページだけを使用した。回答を単語一致だけでなく原文と照合した。
- **重複:** 1〜5ページに同一の型番説明がある資料で、型番質問の出典が1件になった。
- **比較:** 光合成と呼吸の両根拠を保ち、前回混入した蒸発6・屈折31ページが消えた。今回の5出典は合成資料の比較対象に関連する。ただし最小の出典数にはなっていない。
- **scope・分離:** library/folder/notebook/current page、別所有者のsource/page/chunk整合性と空folderの通常回答fallbackを確認した。bodyの偽account情報は所有権を変更しない。

## 今回どこまで実証したか

私有helperのdetail probeでは、実Embedding132ms・実reranking285msで、初期neighbor readsが`[6,1,5,2,3]`、最終出典が`[6,1]`、原文根拠位置が2箇所となった。実モデルを通した全文条件保持と完全一致重複削減は確認した。

**価格が初期Top5に入っていたため、reserveからの不足情報補充は発動していない。** この実環境試験から「欠けた価格を後から実際に補えた」とは主張しない。その経路はローカルの正常/障害/停止/範囲/削除テストで検証済みだが、自然に不足が生じる実候補順位での確認は残る。

一般的な仕組みの意味的網羅性は自動保証しない。比較・複合の同一テーマの異なる説明は5出典を残す。別文書や言い換えの重複を機械的に削除しない。

## 100ページ確認

以前作った合成100ページPDFから抽出済みのテキスト（text-layer80ページ＋合成scan20ページ）を再利用。5ページ×20batchで100chunkを登録し、登録91.924秒。最終登録からreadiness readyを観測するまで81.434秒（polling観測値、正確な反映瞬間ではない）。光合成の7回の検索は全てgrounded・出典1ページのみ。

100chunkすべての1024次元・有限値・owner/source/page metadata一致を確認。同一sourceHash再登録は100ページskip・追加Embedding0。別sourceの機器資料6ページと別合成owner1ページも登録した。

今回はPDF再読取・新規画像OCR・実紙100ページ・実iPadの評価ではない。既存の合成OCR文字列の検索を確認した。

## 初期の中断と対処

最初の3試行は同意ゲートまたは登録中に中断し、すべて削除・無効化した。うち1回は5ページだけ登録したため追加Embedding5件が発生した。2試行は応答内容を十分記録できず、原因を断定できない。記録できた試行では登録前に503 `AI provider review pending.`が返った。

失敗した検証配信版の保存bindingはRAG_ENABLED/AI_PROVIDER_APPROVEDとも文字列trueだった。Wranglerの複数--var集約も独立確認した。実HTTPを処理したversionを採取していないため、伝播/別versionによるものかは**未確定**。ゲートを外すコード修正は行っていない。

最後の試行は配信後60秒待機し、同意なし登録POSTの403を3回連続確認してから開始。100ページ初回登録は一時retry0で完了した。再発する場合はリクエストの配信version/coloを本文なしで記録し、原因を追う必要がある。

## 配信・安全・復旧

開始時の配信版f17462de-9526-48c6-911c-f032361c4904ではRAG statusが404だった。最新版を無効状態で配信し、認証ゲートとstatusを確認してから一時有効化した。配信snapshotはrepo srcと一致、frozen Workerテスト864/864成功（43.276秒）、dry-runビルドと独立安全レビュー済み。

- 検証用有効版: cb34f308-2e9f-4d1c-8d51-7c116217b8ca。
- **最終active版: 40606bdf-ed0e-4491-8921-51e845e5c1c3**、RAG_ENABLED=false / AI_PROVIDER_APPROVED=falseをversion bindingと公開status HTTP200 enabled=falseで独立確認。
- 一時GEMINI_API_KEYは開始時不存在、終了時もsecret名一覧に存在しない。既存3secretは維持した。
- 今回4試行の合成owner計8名についてD1 sources/pages/chunks0、FTS全体0、専用Vectorize全体0を独立確認。削除バリア8件は保持。session・検証用KV metadata・確認用sessionも削除済み。
- 私有helperはloopback+秘密キー+realSession+固定合成ownerのみ。owner/accountKey filterとD1のscope/削除条件を維持。サーバー停止、一時credentialファイル削除済み。
- 実資料・個人の学習内容は外部送信していない。本文・AI prompt・Embedding値の運用ログは追加していない。合成回答は私有一時ファイルに保存し、repo JSONには集計のみ。

元の停止設定への再配信をロールバック手段とし、削除/schemaを保持した。migration/binding/恒久secret/iOS変更なし。検証用チャット上限はowner10・全体40（同日の既存利用分を含む）、実行側は公開11問・HTTP120回で制限。helper AI60回の上限は公開API分を数えないため総モデル上限ではない。終了時に一時上限を外した。

## 費用・プライバシー・残る作業

今回成功runで本文Embedding107chunk（PDF100＋機器6＋別owner1）、中断runで5chunk。再登録の追加Embedding0。質問Embedding/reranking/Gemini、readiness/削除・D1/Workers/Vectorize操作は別途発生した。Gemini usageMetadataを公開APIは返さず、実請求総額は未確認。短いprobeのモデル時間や本文文字数から請求額を断定しない。

今回、外部送信先・保存種類・プライバシーポリシーの変更なし。

残る作業:
- 初期Top5から欠ける情報をreserveで補う実候補順位のケース評価。
- 人間が確認した独立の質問・実資料による回答/引用の精度評価と、先頭年指定等の既知parser制約。
- 同じテーマの冗長な出典の改善。意味的に必要な複数の説明は維持する。
- 配信直後のprovider gate不一致が再発する場合の原因特定。
- 実紙OCR・実iPadの引用タップと本番の費用監視・契約/同意・運用準備。

[集計結果](RAG_EVIDENCE_SELECTION_STAGING_RESULTS.json) / [ローカル実装](RAG_EVIDENCE_SELECTION_REPORT.md)。本番は引き続き未有効化。

Projectの資料の更新が必要: [設計] HYBRID_RAG.md、[リリース] 00_残タスク表.md、今回release記録。Desktop複製/Projectアップロードは行っていない。

## 続報

[不足情報補充の障害回復確認](RAG_RESERVE_RECOVERY_STAGING_REPORT.md)で、
実モデルと限定した初期本文欠落を組み合わせ、reserve補充→Gemini回答まで確認した。
自然順位での検索ミス回復率は引き続き未評価。
