# 段落ID方式の実装・限定実測（2026-10-10）

モデルに引用文と文字位置を生成させる方式に代わり、アプリ側で確定した段落IDを選ばせるoffline試作品を実装した。実Geminiでは2問に対して構造検証を通過し、選択した全文に暫定の必須事実が残った。3問目で429となり停止したため、条件・数式・分散情報等の実モデル評価は未完了。公開RAGには接続していない。

## 設計と受け入れ条件

Plannerによる独立設計、安全レビューとコードレビューを実施。外部APIを扱うためfullの安全確認と運用上限を維持する。作業先 `.worktrees/rag-wip`、既存 `codex/rag-wip` ブランチ。

受け入れ条件は、原文quote/offsetのモデル生成を不要にし、決定的IDから原文・参照元を取り出せること。不正ID・別参照ID・古いsnapshot等は拒否し、選択された参照の全文と元source/pageを保持する。形式成功を意味の完全性と同一視しない。`safeReferences`は元baseline、`productionEligible=false`を全結果で維持する。

## 実装

新規:

- `mcp-server/scripts/rag-quality/paragraph-proposal.mjs`: 原文段落mapping・version2 protocol・検証/fallback。
- `mcp-server/scripts/rag-quality/paragraph-proposal-live.mjs`: 合成固定問題の実モデルshadow評価。
- `mcp-server/src/rag-paragraph-proposal.test.js`: 22件の回帰テスト。
- `docs/RAG_PARAGRAPH_PROPOSAL_RESULTS.json`: 実測メタデータと評価。
- 本報告。

更新:

- `selection-proposal-gemini.mjs`: 評価callerが固定のparagraphSchemaを渡せるschema引数を追加。従来のschemaがdefaultであり、以前の試作も維持。
- `docs/HYBRID_RAG.md`: 現状追記。

1. 既存proposalTaskで最大5参照、各6,000文字、全体24,000文字を検証し、本文をコピー・固定する。
2. 既存paragraphSpansの**空行境界**で分割し、ID/referenceId/UTF16 start/end/元textを対応付ける。本文・数式・否定・条件を正規化しない。
3. protocol2と本文・参照元・段落mappingからsnapshotを生成する。モデルへはIDと元段落を渡し、ラベルや文字位置は渡さない。
4. 返答は全候補のreferenceId/action/reason/paragraphIds。原文quote/offsetやsource/pageの生成は許さない。追加key、未知/別参照ID、重複、不足候補、空根拠等を拒否する。
5. 合格時は元参照の全文をshadowへ残す。段落IDは根拠位置の対応に使い、参照本文を段落だけへ縮めない。不正/abstain/障害/5秒timeoutはbaselineへ戻す。

上限は全体200段落。超過時はpreflightで拒否しモデルへ送信しない。途中で切り捨てて末尾の条件を落とす処理はない。この試作品自体は認証を実装せず、将来の呼出元にowner/scope確認済み候補を要求する。

空行のない文章はページ/参照全文が1段落になる。現在の生物合成資料は単一改行が中心で、段落粒度が粗い。この結果から「最適な根拠段落を細かく特定できた」とは言えない。句読点・見出しによる再分割は今回混ぜていない。

## 実モデル結果

評価用Gemini3.6 Flash、temperature1/minimal thinking、各5秒・逐次・retryなし。4問を予定し、429/認証/5xxで残りを停止する。入力は合成資料のみ。

| 質問 | 結果 | 時間 | 出典数 | 暫定必須事実 | 補足事実 |
| --- | --- | --- | --- | --- | --- |
| 光合成と呼吸の比較 | HTTP200・形式合格 | 3,082ms | 5→3（page3/5/1） | 2/2保持 | 3→1 |
| 光合成の入力と出力 | HTTP200・形式合格 | 2,867ms | 5→1（page1） | 1/1保持 | 4→0 |
| 材料と生成物が分散する反応 | HTTP429・fallback | 277ms | 元の3件維持 | モデル選択は未評価 | — |
| 暗所条件を含む反応 | 未送信 | — | — | 未評価 | — |

成功2件のモデルVersionはgemini-3.6-flash。ID・snapshot・参照所属の検証を通過し、モデルにquote/offsetを返させずに原文へ対応付けられた。

必須事実3/3は、**選ばれた参照の全文にラベルの事実が含まれる**という評価。witness段落そのものの関連性、モデルの理解、最終Gemini回答の正しさを測ったものではない。supportingは有用な補足であり、削られた補足を誤引用や不要情報と断定しない。

成功2件はdevの同じ生物資料で、一般精度の証拠には不足する。人間/教師のラベル確認、盲検holdout、実教材は未評価。429の細かなquota種類も未特定。従来方式の503/invalid_spanと今回の成功は、測定時点・schema・入力表現が異なるため、変更だけが改善原因と断定しない。

## テスト・レビュー

新規22テスト成功。決定性・UTF16/emoji・数式・条件・単一改行の粒度・200段落境界・別source/crossref・旧protocol/snapshot・不正出力・abstain/timeout・全文保持・promptデータ境界・5xx停止を検証した。全IDが正しくても必須条件を落とす提案の反例も検証する。

模擬providerで既存16問の全文baselineを保持した返答を再生した結果は、形式の契約確認であって実モデル精度ではない。新規と既存transportの関連38件成功。全Workerテスト970/970成功（約83.2秒、失敗・skipなし）。独立コード/安全レビューは問題なし。iOS・実iPadは今回未実施。

## 費用と公開状態

成功2callで観測した入力3,263、回答673、total3,936 token。思考欄は未記載で、totalは入力+回答と一致する。2026-10-10の[公式料金](https://ai.google.dev/gemini-api/docs/pricing)でキャッシュ割引なしの有料Standard相当は:

`(3263 × 0.75 + 673 × 3.75) / 1,000,000 = $0.004971`

成功分のみの換算額で、請求額や全実行費用ではない。無料/有料tierは未確認、429のusageと課金は不明。

モデル本文・原文・prompt・APIキーは新規ログ/結果へ保存せず、結果にはstatic項目・ID・数値だけを保存した。秘密情報の一時ファイルは作っていない。プロセスは終了。migration/binding/secret/Cloudflare flags/DB/Vectorize/public Worker/iOS/プライバシーポリシーの変更なし。ロールバックは評価ファイルを除去しschema引数の追加を戻す範囲で、サーバー操作は不要。

## 次の作業

利用制限を確認してから、分散した入力/出力、否定条件、数式、別資料の裏付け、holdoutの評価を続ける。必要事実の漏れ、補足を省く妥当性、最終回答、遅延・費用・実教材での品質を確認し、人間のラベルも検証する。今回の2問の成功だけでは製品接続や本番有効化を行わない。
