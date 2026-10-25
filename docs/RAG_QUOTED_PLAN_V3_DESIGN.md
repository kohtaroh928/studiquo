# 評価用TaskPlan v3：原文引用からの位置解決

## 問題と範囲

2026-10-15の固定候補1回で、最初のtaskの最初のsubjectについて `span_quote_mismatch` を確認した。原文位置と引用textが一致しないことは分かるが、textとoffsetのどちらが誤りか、モデル内部理由、旧runとの原因一致は不明。再送はしない。

この単位では数値offsetをmodel-facing契約から除く評価専用候補を実装する。リスクはStandard（純粋なオフライン入力検証、新規モジュールのみ）。公開API/検索/認可/利用量制御/本番prompt/iOS/既存runnerは変更しない。既存v2、oracle、質問body、journal、凍結結果を保持する。

## 契約と受入条件

- root versionは3。status/tasks/unresolved、操作、unknownのpermissionと根拠支持はv2と同じ。
- spanは厳密な `{text,prefix,suffix}`。textは原文の非空部分（最大4096 UTF16 code unit）、prefixとsuffixは直前・直後の連続原文（各最大128、空可）。三つともUnicode scalarとして妥当な文字列であること。
- サーバーは質問内のtextの全出現を重複位置も含め走査し、前後引用が一致する位置だけを残す。候補が一つの場合だけ、質問から数えたUTF16 start/end/textにする。0件は不一致、複数は曖昧として固定error。最初の一致を採用しない。
- Unicode/空白/改行/全半角/結合文字を正規化しない。fuzzy検索、綴り訂正、case依存分岐、モデルoffsetの補正をしない。文字をsurrogate途中で分割しない。結合文字・ZWJは文字列をそのまま照合し、grapheme cluster境界の保証は行わない。原文内のscalar境界の部分引用として扱う。
- question UTF8最大16384byte、plan JSON最大32768byte、task16/unresolved8/各list4を維持。exact keys、型、配列上限を走査前に検証する。循環・非JSON値・無効型は固定error。原文や上流例外をerrorへ含めずログも出さない。
- 新v3を明示指定した入力だけを解決する。失敗したv2の黙示救済や旧parserへのfallbackを追加しない。解決後のv2を凍結validatorで最終検証し、重複id/span、status矛盾、permission偽装を拒否する。
- 原文一致は対象・属性の意味上の正しさや抽出漏れがないことを保証しない。意味完全性はpending、根拠支持はunknown、releaseAccepted=falseを維持する。

## 検証・導入順

1. 独立Plannerによる設計確認。
2. pure schema/resolverと合成問題のテスト（反復語、overlap、日本語、絵文字、結合文字、改行、無一致、曖昧、サイズ、権限、重複、元v2との対応、入力不変）を追加。
3. 対象/既存サーバーテスト、独立コードレビュー。
4. 結果をNotion/本書/handoffへ記録。評価用schemaのコード合格をモデル精度改善と呼ばない。

APIの次段階は別単位：質問のみのv3入力、response adapter、評価予算・manifest・有限runを設計/確認してから扱う。今回は外部送信0、キー読取0。未使用20問や実学習内容は使わない。

## 障害・停止と後戻り

曖昧引用では自動再生成しない。quote_ambiguousは引用表現の位置が未確定という意味で、質問そのものが曖昧だという判定やneeds_clarificationへの自動変換ではない。誤った引用が偶然別の実在箇所と一致すれば意味誤りは残るため、人手oracleとの独立評価を継続する。前後128文字で分離できない反復も未解決として返す。新moduleを使わなければ従来動作を保持でき、削除しても既存journal/本番へ影響しない。新schemaはまだ本番へ接続しない。Projectの資料の更新: なし。


## 実装・レビュー記録

新 `mcp-server/scripts/rag-quality/task-plan-quoted-v3.mjs` と専用 `mcp-server/src/rag-task-plan-quoted-v3.test.js` を追加。新schema factory/純粋resolverのみで既存コードへ接続しない。JSONはplain object/array/scalarのみ、accessor/symbol/sparse array/非有限数/循環/特殊objectは拒否し、byte予算を走査中に消費する。aliasはJSONと同様に独立コピーする。成功は元v2 validatorを経たplanだけで、操作/role/task数を変えない。

独立設計レビューの受入条件を反映。独立コードレビューで、例外判別のinstanceofが敵対的Proxyの例外を漏らすMediumを確認し、内部発行エラーのWeakMap識別へ置換した。二重Proxy throwの回帰テストを追加し、元の任意errorを参照しない。

専用13テスト成功。既存開発8問/13scopeの手書き注釈から作った引用を元の位置へ戻せることも検証した。これはoracleを使ったオフライン互換検証で、モデルにoracleを渡したものでも、モデル抽出の成功13件という意味でもない。追加API/キー読取0、未使用20問不変、旧3runのlock/凍結validator hash保持を確認。最終独立レビュー/全Worker結果は後記する。


## 最終確認

専用13件、全Worker1,393件成功（失敗/skip0、44.7秒）。最終ログ `/private/tmp/studiquo-quoted-v3-all-final.log`、本文なし結果 [RAG_QUOTED_PLAN_V3_RESULTS.json](RAG_QUOTED_PLAN_V3_RESULTS.json)。独立再レビュー13成功・Medium解消・未解決High/Mediumなし。差分/構文確認済み。iOSと実モデルは今回未実施。新契約を使った実モデルの引用選択・要求分解品質は未評価であり、RAG全体の完成や精度改善を主張しない。
