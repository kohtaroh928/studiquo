# TaskPlan v2: 質問のみの構造化入力準備

2026-10-15、rag-wip。回答漏れを確認する前段として、固定合成6問を質問だけの構造化planner入力へ組み立てた。**オフライン入力準備であり、実モデルの抽出・APIのschema受理・精度改善は未確認。** 本番v1、凍結bank、未使用20問、旧初版の結果は保持。

## 範囲と受入条件

Standardの小単位として独立Planner確認後に実装。`mcp-server/scripts/rag-quality/task-planner-request.mjs`と専用テストを追加した。質問の順序/本文保持、gold非混入、固定設定とサイズ、schema変換、外からの変更分離、境界拒否を受入条件にした。UI/旧アプリ互換/DB/本番APIへ影響なし。新しいキー読取・通信・課金・live CLIは追加していない。

- 初版の別分野6問からquestionだけを取り出す。評価ID、正解タグ、期待span、期待値、資料、履歴は入力しない。操作enumがoracleと同じなのは規約の共有であり、gold混入の判定は語句検索だけに頼らず構造と由来を見る。
- 固定指示に質問を補間せず、user JSONのquestionへそのまま入れる。質問内の役割変更や偽命令は削除して別問題にせず未信頼データとして保持する契約。モデルが守れるかは未評価。
- 回答・資料支持・比較許可を推測せず、質問で求められた属性/対象/状況/操作を分解する。UTF-16引用offsetを要求するが、自動補正して形式成功に見せる処理はない。
- indexは整数0〜5のみ、余剰引数拒否。Luna/medium/default/store:false/stream:false/max_output_tokens8192固定、body最大24KiB。返すbodyはcloneで、変更して次の入力を差し替えられない。
- `text.format`のjson_schema/strict:trueを使用。元v2 schemaのcloneを再帰変換し、constを単値enumへ、文字列長制限をwireから除外する。元schemaとvalidatorは不変。出力は次工程で必ず元validatorへ通し、UTF-16引用/長さ/unknown/root間整合を再確認する。形式一致を意味完全性と認定しない。
- request manifestは質問順序、質問、固定指示、wire schema、各bodyのhashとbytesだけ。入力/回答本文は記録しない。modelEvaluated=false、releaseAccepted=false。

## 検証と制約

対象5件・関連23件・Worker全1,333件成功（失敗/skip0）。独立対象5件成功、High/Medium指摘なし。初版hash/過去結果/rubricとruntimeの固定v1出力が不変であることも確認。追加API0、キー読取0、評価API費用0。iOS/実検索/OCR/PDF/iPadは未変更・未再評価。schemaをローカルで組み立てられることは、OpenAIが受理した証明ではない。

今回の6問は開発用で、人間oracle確認はpending。厳密spanが別の妥当なspanを不一致とする可能性と、UTF-16 offsetをモデルが誤る可能性を独立意味レビューと分けて記録する。

## 次の単位と停止方法

次は固定requestを既存の予算予約/journal/送信上限/初失敗停止へ接続する。非stream JSON形式なので既存SSE transportをそのまま流用しない。completed状態、拒否、不完全出力、JSON/UTF-16検証、usage、時間/bytes上限、先行journal、曖昧な送信結果を再送しない扱いを独立安全レビューしてから実Luna評価へ進む。予算・料金は実行前に確認する。今回のmoduleを使わなければ評価を停止でき、本番のrollbackは不要。本番接続/生成後validator/自動修正の採用判断は別工程。

参照: [OpenAI Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs)（2026-10-15確認）。Responsesのtext.format、strict schemaとローカル意味検証の責務を分けて利用する。

deploy/migration適用/push/merge/commit/secret変更なし。Projectの資料の更新: なし。

## 2026-10-15 継続: 非stream応答のローカル検証

次の前提として`task-planner-response.mjs`と専用テストを追加。固定indexの質問/request hashへbindし、別質問やモデル/上限を渡す引数は設けない。純粋なparserで、通信/キー/予算/本番処理を追加しない。

- raw JSON最大256KiB、plan text最大32KiB。object=response、status=completed、error/incomplete_details=null、model完全一致を要求する。実HTTP読取中のbytes/deadline制限は後続adapterの責務で、このparserだけでは通信中の制限を保証しない。
- outputはreasoningと1つのassistant completed messageだけ。message内は1つの非空output_textのみ。refusal/tool/複数message/混合text/コードフェンス/不完全情報を拒否し、自動補正・自動再試行しない。reasoning statusは省略/ completedを許し、null/その他を拒否する保守的規約。実APIとの互換性は未確認。
- input/output/total/reasoningを安全整数で検証し、input最大32768、output最大8192、total=input+output、reasoning<=output。cache詳細があるときは既知のcached_tokens/cache_write_tokensのみを認識し、非負/各input以下/合計input以下。未提供はnullで保持、未知fieldは拒否する。実請求額や料金の承認を意味しない。
- JSON planを元v2 validatorで検証。日本語のUTF-16位置をbyte位置と取り違えた反例、改変引用/支持偽装を拒否する。返すplanはclone。request/raw hash、正規化usage、semanticCompleteness=pending/releaseAccepted=falseを返す。rawやparseエラー詳細を例外message/causeへ付けない。例外の理由は固定コードだけ。

対象7/関連19/Worker全1,340テスト成功（失敗/skip0）。独立対象7成功、High/Medium指摘なし。初版hash/旧結果/rubricとruntime固定v1出力不変を確認。これらは手書きoracleから作ったモック応答で、モデル抽出の実績ではない。追加API0、runtime v1/既存入力は不変。

次は新しいparserへ非stream JSON transportと既存方式のprivate予算journalを接続する。返るplanには質問の一部が含まれるためstdout/共有ログ/本文なしRESULTSへ保存しない。呼出前のdurable予約、固定6送信上限、初失敗停止、未確定送信の再送禁止、費用上限と料金確認、secret検査、応答読取deadline/bytesを独立安全レビュー後に実行する。

参照: [OpenAI Structured Outputsの拒否・不完全応答](https://developers.openai.com/api/docs/guides/structured-outputs)（2026-10-15確認）。Projectの資料の更新: なし。
