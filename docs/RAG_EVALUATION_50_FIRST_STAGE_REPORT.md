# 50問評価：実行runnerと最初の6回答

2026-10-13。[runner設計・安全な再開](RAG_EVALUATION_50_RUNNER.md)と[結果metadata](RAG_EVALUATION_50_RUNNER_RESULTS.json)。

## 実装・検証

新規 `mcp-server/scripts/rag-quality/evaluation-50-live.mjs` と `src/rag-evaluation-50-live.test.js`。固定資料の回答層adapter、private durable journal、manifest変更拒否、成功済みskip、失敗/成否不明停止、各回6/dev全体60送信制限、保守予約予算を実装。予算は同じdirectory単位で、新directoryでの再試行を自動化しない。journalを巻き戻さない。

新規10件と全Worker1,236件成功、失敗・skip0、差分確認成功。fsync失敗の送信0、返答保存失敗の再送0、429/503・未完了・usage不明/超過・モデル違い・反射キーの停止、同時実行/lock/権限/symlink拒否、設定変更/途中journalの再開拒否、60件完了後の送信0を確認。独立code review関連15件、安全review新10件成功。High/Mediumなし。安全reviewのfd検査補強も実装・再検証。iOS/production未変更、iOS今回未実行。本番反映なし。

## 最初の実API評価

調整用conditions-01〜03を両style、6送信/completed。条件・例外・否定を確認。固定合成資料と最小base prompt、production request builderとgrounded回答policyによる分離評価であり、full handleAI/実検索/構造化出典/partial・clarification判断の確認ではない。モデルはLuna、medium、出力上限2,048、Standard。

Codexと独立AIの内容確認では、主要判断は6回答とも正しい。5回答は全要求項目を確認。最初のsource_only回答は土曜不可・申請・平日は正しく答えたが、「会員のみ」という入場資格を独立に明示していない。質問が会員を前提としているので重大な誤答ではない一方、bankが要求する全条件の明示という厳格採点では網羅不足候補。無条件に6回答すべて満点とはしない。人間の判定はpendingとし、少数の候補だけでpromptを再調整せず、残り調整用の傾向も確認する。

一般知識の無表示追加、未記載の仮定例、本文の出典生成は今回の6回答で見られない。実際の回答本文はprivate journalに保持し、repo/Notionへ転記しない。

入力15,671/出力293/合計15,964tokens、usage上の思考tokensは0。設定はmediumだが、思考tokensが毎回発生することを意味しない。上流1.292〜2.780秒、平均2.081秒。全入力を通常非cachedとして計算したStandard概算0.0017136米ドル、実請求ではない。永久保持する保守予約は0.03072米ドルで、概算利用額とは別。

## 次の作業

同じjournalで次のdevelopment段階へ進み、残り54回答を小分けに実行・採点する。未使用20問/40回答は送信していない。実行入口はdevだけで、holdout実行・不明送信の監査付き解決・人間の正解確認・model snapshot固定・full production prompt照合は残る。実検索/PDF/OCR/iPad・他モデルの確認も別工程。

今回の結果から汎用精度や50問の合格率を算出しない。release判定ではない。キー/個人情報/実ノートのfixture化、push/merge/commit/deployは行わない。

Projectの資料の更新: なし。
