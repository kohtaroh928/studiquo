# 原文根拠付き出典選択の試作（2026-10-10）

前回のshadow評価を受け、意味を判断するAIから出典選択案を受け取り、実在する候補・原文に基づく提案か検証するoffline試作品を実装した。公開retrievalには接続していない。今回は構造検証と必要情報の評価を分離できることまでが完了範囲で、モデルによる意味判断や出典削減の品質改善はまだ検証していない。

## 設計・受け入れ条件

Plannerの独立設計に従い、候補・質問と同じsnapshotであること、候補IDが実在すること、引用spanが原文と完全一致することを検証する。これらを満たしても必要事実を網羅したとは認定しない。条件・否定・数式を落とした「形式上正しい」提案を、独立ラベルの評価側で検出することが主要な受け入れ条件。

製品API、iOS、認証、D1/Vectorize、migration、binding、secretは変更しない。作業先は `.worktrees/rag-wip`、既存の `codex/rag-wip` ブランチを継続。Standardの評価用実装としてPlannerとCode Reviewerを使用した。

## 変更したファイル

新規:

- `mcp-server/scripts/rag-quality/selection-proposal.mjs`: task・promptの生成、提案の構造検証、時間制限とfallback。
- `mcp-server/scripts/rag-quality/selection-proposal-evaluate.mjs`: 既存fixtureに対する手書き模擬提案の再生・独立ラベル評価。
- `mcp-server/src/rag-selection-proposal.test.js`: 回帰テスト25件。
- `docs/RAG_SELECTION_PROPOSAL_RESULTS.json`: 再現可能な評価結果。
- 本報告。

更新: `docs/HYBRID_RAG.md` に試作の範囲と未実施事項を追記。

## 提案を処理する流れ

1. 呼び出し側が所有者・検索scopeを確認済みの候補を渡す。この試作品自身に認証機能はない。候補最大5件、各6,000文字、合計24,000文字、質問2,000文字で制限する。本文・source・page・title・順序・質問からSHA-256 snapshotを作り、コピーを固定する。
2. モデル向けにはsystem指示とuserのJSONデータを分ける。本文・見出し・質問を命令として扱わないよう指定し、必要な条件・否定・数式・相違点を保持するよう求める。正解ラベルは入力しない。元sourceIdは渡さず、資料の区別用sourceGroupと元pageNumberをデータに含める。
3. 提案は `{version:1, snapshot, decision, decisions}`。`decision`は`select`または`abstain`。selectでは全候補に一つずつ`referenceId/action/reason/spans`を要求する。spanは元本文のUTF16 `start/end/quote`。自由な出典・ページ・confidence・回答は受け付けない。
4. snapshot不一致、未知/重複/未分類ID、追加キー、範囲外/不正引用、絵文字途中のoffset、空選択、32,768 UTF8 byteを超える出力を拒否する。
5. proposerは注入する関数。既定2秒、最大設定5秒で終了し、timeout時はAbortSignalを送る。通信adapterは未実装。任意のproviderがsignalを無視して行う処理まで強制停止できるものではない。不正・abstain・障害では元の候補を返し、providerのエラー本文は結果へ含めない。
6. 正常時も、結果をshadow用候補と安全用候補に分ける。`shadowReferences`は選ばれた元候補の全文、`safeReferences`は常に元baseline。`productionEligible`は常にfalseで、モデルやオプションから有効化できない。出典のsource/pageと本文はモデルから生成せず元候補から取得する。

snapshotは同一入力の確認であって認証や署名ではない。別ユーザーの候補を取り込まない保証は既存retrieval側の責務。試作を製品へ接続するには、その境界の独立セキュリティレビューが別途必要。

## 検証結果

8件の**手書き模擬提案**を再生した。実モデルの出力ではなく、検証器の能力と限界を測る反例である。正解を見て作った提案も含むため、モデル性能・検索精度・正答率・汎化性能を示さない。

| 項目 | 結果 |
| --- | --- |
| 構造検証を通過した提案 | 8/8 |
| 通過したが必要事実を落とした提案 | 4/8 |
| 安全用baselineで必要事実を落とした質問 | 0/8 |
| 製品利用可能と認定した提案 | 0/8 |

光合成/呼吸の機構を2件、入力/出力を1件にする模擬提案は暫定requiredラベルを満たした。一方、材料・結果が分散する反応、暗所で起こらない条件、数式の適用範囲、否定による区別を落とした提案も、原文引用自体は正しいため検証を通過した。**構造検証だけでは意味の漏れを防げない**ことを回帰テストとして固定した。公開回答はこれらの選択案を使用しない。

既存fixtureは独立エージェントのラベル確認を反映済みだが、人間・教師の確認は未実施でholdoutも非盲検。supportingの補足を削ることが利用者の期待に合うかは未確定。質問外資料のラベルがないため、除外性能も今回の対象外。

対象テスト25/25成功。元本文とsource/pageの維持、snapshot、UTF16、予算、不正出力、abstain、provider障害、timeout、正解ラベルの非混入、意味的欠落の検出を確認した。

prompt injectionのテストは、本文に役割風の指示を入れてもJSONデータの枠内に置くことと、指示に影響されたような提案でも製品ゲートを開かないことを確認した。**実モデルが注入指示に従わないという保証は未検証**。

独立コードレビューで指摘なし。公開経路 (`src/rag/`、`ai.js`、`app.js`) から試作をimportしていないことも確認した。全Workerテスト914/914成功（約44.8秒、失敗・skipなし）。iOS・実iPadは今回未実施。

## 運用・安全・残る作業

今回外部APIを呼ばず、追加のモデル費用はない。合成資料だけを使い、本文・promptをログに出す処理は追加していない。秘密情報・ユーザー資料の新規保存もない。Cloudflareの公開状態、プライバシーポリシー、データ削除処理を変更していない。ロールバックは評価ファイルを取り除く範囲で、サーバー操作は不要。

次は、この受け口に実モデルのadapterをつなぐ**shadow評価**。合成資料に対する提案を独立ラベルで評価し、形式不正率・必要事実/条件の欠落・補足保持・遅延・費用を測る。原文一致と意味の完全性を混同しない。人間または教師が正解を確認した未見資料でも比較し、必要情報を落とす場合は元baselineを維持する方針を検討する。製品接続・本番有効化、実紙OCR、実iPadでの評価は未完了。

再実行は`mcp-server`で:

```sh
node scripts/rag-quality/selection-proposal-evaluate.mjs ../docs/RAG_SELECTION_PROPOSAL_RESULTS.json
node --test src/rag-selection-proposal.test.js
npm test
```
