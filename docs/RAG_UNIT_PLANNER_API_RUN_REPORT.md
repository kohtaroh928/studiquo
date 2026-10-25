# v4要求抽出：実Luna評価の結果

2026-10-16。新runで固定開発8問を1+3+4の段階で実行し、各段階を独立意味監査した。初回の料金/source/manifest/旧lock保全を確認し、stage0/1は実監査成果物のhashを登録した後だけ後続へ進めた。本番v1とRAG全体の構成は変更していない。

## 結果

| 項目 | 結果 |
| --- | --- |
| 実API送信/形式検証完了 | 8 / 8 |
| 通信/形式エラー | 0 |
| 独立意味監査 | 7問reviewed_match、1問mismatch_detected |
| 最終状態 | stage2 stop、generationComplete=true、finalReviewComplete=false |
| 再送 | 0、lock保持 |
| model / effort | gpt-6-luna / medium |
| 応答時間（要求抽出のみ） | 中央値4.200秒、最短3.456秒、最長7.318秒 |
| 8送信のelapsed合計 | 36.683秒（監査待ちを含む全作業時間ではない） |
| input / output tokens | 10,066 / 2,120 |
| reasoning tokens | 646（outputの内数、二重加算なし） |
| cached / cache write | 0 / 10,042 |
| usage由来の費用推計 | 0.00231765 USD |
| 予約 | 65,536 microUSD（0.065536 USD、実請求ではない） |

費用は2026-10-16に確認した[公式Luna単価](https://developers.openai.com/api/docs/models/gpt-6-luna)から、非cache/write input24×0.10、cache write10042×0.125、output2120×0.50を各100万tokenあたりで計算した。請求明細や税等の実支払額を確認した値ではない。

[詳細metadata](RAG_UNIT_PLANNER_API_RUN_RESULTS.json)と、独立意味監査の[stage0](RAG_UNIT_PLANNER_STAGE0_AUDIT.md)・[stage1](RAG_UNIT_PLANNER_STAGE1_AUDIT.md)・[stage2](RAG_UNIT_PLANNER_STAGE2_AUDIT.md)を保存した。共有文書へ原質問/plan全文/raw response/秘密を転記しない。

## 見つかった問題

index5は条件・例外の2要求の内容をattributeラベルに保持しているが、明示された各対象をsubjectsへ出していない。操作や内容全体の消失ではなく、対象専用roleへの構造化漏れである。現8観点規約ではsubjects不合格とし、stage2はstopにした。helperのoracle相対missing/extraはroleを含む対応要件の未達であり、質問の全情報が消えたという意味ではない。

今回8問では従来のquote位置不一致による停止は起きず、schema/参照/JSONの処理は完了した。一方、形式合格は意味合格を保証せず、独立reviewで実際のrole欠落を検出できた。小標本の7/8を汎用正答率として扱わない。

## 確認範囲と残件

- 全8問が1unitの短文。複数文/複数unitの参照選択を実モデルで検証できていない。
- 原oracleの人間確認はpending。独立エージェントの判定であり、人間gold確定ではない。
- これは質問から必要な回答項目を抽出する部分の評価。実検索・回答生成・OCR・100ページPDF・実iPadの品質ではない。
- 使用量の合算と最終23recordのchain/source/job/予約/artifact/stopを独立安全監査した。旧4runのsource/journal/lockと新stop lockを保持し、合計5runの解除・再送をしない。
- 前工程の全Worker1,540件成功とcode36/安全43成功を保持。今回はコード変更なしで、全テストの再実行はしていない。新たな検証は実8問と実成果物の3段階独立監査である。

次は[対象roleの汎用修正案](RAG_UNIT_PLANNER_ROLE_FOLLOWUP.md)に従い、凍結済みの現promptを直接変更せず別candidateを設計する。明示対象の保持と対象不在で捏造しないこと、名詞を無差別にsubjectsへ入れないことを、別題/複数unitの開発oracleを先に固定して確認する。未使用20問は調整に使わない。追加APIは次の有限設計・独立gateとして扱い、このstop runを再利用しない。

Projectの資料の更新: なし。
