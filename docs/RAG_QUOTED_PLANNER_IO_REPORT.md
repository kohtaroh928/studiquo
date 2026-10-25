# 評価用Quoted TaskPlan v3の入出力

## 範囲と受入条件

2026-10-15。前段の[v3引用契約](RAG_QUOTED_PLAN_V3_DESIGN.md)に対応した、固定合成開発8問のrequest factoryとオフラインresponse parserを追加する。Standard変更。新moduleとテストのみ、本番・旧v2/paired request/parser/runner・oracle・実行journalは変更しない。ネットワーク送信、キー読取、任意問題/モデル/設定override、保存やログは実装しない。

requestは既存candidateの質問と分解規約を保持し、引用の表現契約・schema名・versionだけをv3へ変更する。比較したい差分は文字位置をモデルに数えさせるか、引用からserverが決めるかである。Luna/medium/store:false/default/max_output8192を保持。固定index0..7、本文24KiB以内。gold/注釈/正解の送信はしない。manifestにはhash/件数/親candidate request hashだけを含める。

responseは256KiB以内・completed・単一assistant message/output_text・正しいmodel・制限内usageを要求し、refusal/不明item/余分message/不完了を固定errorで拒否。plan JSONは32KiB以内、v3のみをresolverへ渡し、曖昧・不一致・不正形式を区別。v2fallback/補正/再試行はしない。戻り値のquotedPlanとresolved v2 planには合成引用本文が含まれるためログや共有RESULTSへ保存しない。requestHashは期待する入力のhashで、上流送信の証明ではない。原文照合が通っても意味完全性はpending、releaseAccepted=false。

## 手順

1. 独立設計レビュー後、新request/responseを追加。
2. 全8mock、schema/固定settings/質問のみ/元candidate差分、不正index/override/immutable、envelope/usage/refusal/未知item/bytes/invalidJSON、v2拒否/quote曖昧/不一致を確認する。
3. 関連/全Workerテストと独立コードレビュー。元body/hash、旧結果、本番を保持。
4. 結果と次の有限評価設計を記録する。実APIにおけるschema受理・モデル成功率・費用は今回未確認。

[OpenAI公式Structured Outputs資料](https://developers.openai.com/api/docs/guides/structured-outputs?api-mode=responses)を確認。wire schemaは既存評価と同じ変換（constをenum化し文字長はlocal側で検証）を使い、ローカル契約を弱めない。APIのschema適合だけで引用位置や意味の正しさを保証しない。

新moduleを使用しなければ従来動作へ影響しない。旧失敗runは引き続きlock保持、今回追加API0。採用済み構成の変更なし。Projectの資料の更新: なし。


## 最終確認

専用9テスト（固定8応答/13scopeのmock）・全Worker1,402テスト成功、失敗/skip0、44.3秒。独立設計/コードレビューで未解決High/Mediumなし。ログ `/private/tmp/studiquo-quoted-planner-io-all.log`、本文なし結果 [RAG_QUOTED_PLANNER_IO_RESULTS.json](RAG_QUOTED_PLANNER_IO_RESULTS.json)。新request/responseの構文・差分確認済み。旧pairedソースと前段v3ソースのhash一致、3runのlock保持を確認。

今回追加API/キー読取0。実APIのschema受理/モデル完了率/意味品質は未確認、iOS未変更・未実施。次はv3専用有限runの予算/manifest/private journal/初失敗停止/独立安全レビューを設計する。旧失敗runの解除・再送や新runnerへの黙示差し替えはしない。Projectの資料の更新: なし。
