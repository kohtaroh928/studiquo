# 50問評価用runnerと安全な再開

2026-10-13。課金/秘密を扱うHigh変更として詳細手順・独立計画・コードレビュー・安全レビューを実施。変更はローカル評価tool/testのみ。productionへ反映しない。

## 評価範囲と受入条件

固定の合成資料・質問・履歴だけを渡し、既存 `buildResponsesBody` と `ragAnswerPolicy('grounded', style)` を使う回答層の評価。最小の専用base promptを用いる。productionの全CHAT_SYSTEM・handleAI・検索・同意・認証・credits・構造化出典・partial/clarification判定は経由しない。検索の取りこぼしと回答の誤りを混同しないための分離であり、この結果だけでアプリのチャット品質を合格としない。

正解・禁止主張・採点条件は送信しない。各対の質問・履歴・資料を同一にし、回答styleだけを変える。50問bankとrubric、生成body、モデル、設定、料金をmanifestへ固定し、再開で変更を検知したら拒否する。

## 上限

- Luna `gpt-6-luna`、medium、Standard (`service_tier=default`)、store=false、ツール/過去response IDなし。
- 1回の起動は調整用1段階のみ、最大6送信。調整用合計最大60送信。未使用20問のlive entry pointはまだ作らない。
- 出力最大2,048tokens（思考を含む）。送信body最大24KiB。入力予約32,768tokensは保守的見積りでありtokenizerによる厳密な上限保証ではない。
- ディレクトリ単位の予約予算0.50米ドル。入力はcache writeを含む保守単価0.125ドル/百万tokens、出力0.50ドル/百万tokens。1送信の予約0.00512ドル、60送信で0.3072ドル。実際の通常入力は0.10ドル/百万tokens。予約値を実請求と呼ばない。

料金は[公式Lunaページ](https://developers.openai.com/api/docs/models/gpt-6-luna)と[料金表](https://developers.openai.com/api/docs/pricing)を2026-10-13に確認。料金変更時はmanifestを変更するため既存journalのまま継続できない。cached入力の割引を予算節約として先取りしない。予約超過・usage不明は後続送信を停止するが、provider側の将来価格変更/見積り誤差を含む請求上限を保証する仕組みではない。

## 永続記録と失敗処理

専用0700ディレクトリと0600journal、同じOSユーザーのみ。symlink/ファイル種別/所有者/権限/複数hard linkと、開いたfdのinodeを検査する。ロックを作り同時起動を拒否する。stale lockを自動解除しない。

送信前にreservedレコードを追記してfsyncする。初回file/directoryの作成も親directoryを同期する。正常completedと回答・usageをdurable保存したものだけ再開時にスキップする。reservedのまま/failed/途中journal/usageなし/未完了/モデル違いは自動再送せず停止する。返答後の保存失敗でもreservedを保持する。予約額は成功後も返却せず、成否不明を過少計上しない。

固定URLのみ、redirect拒否、body読込まで60秒、起動全体の外部通信期限6分。最初のエラーで残りを送らず、retryはしない。APIキー・raw providerエラーは保存しない。raw合成回答はprivate journalだけ、repo/Notionはmetadataと所見のみ。

hash連鎖は事故検出用で、署名/耐改ざん保証ではない。同じOSユーザーが末尾を変更したり古いjournalへ巻き戻したり、新directoryを作る操作までは防げない。評価は一つの固定directoryで続け、失敗時に新directoryを自動作成しない。

## 実行と残件

`mcp-server`内で `STUDIQUO_RAG_E50_REMOTE=true node scripts/rag-quality/evaluation-50-live.mjs /private/tmp/studiquo-rag-e50-development-20261013`。この同じdirectoryへ次の起動で次段階を送る。既存の安全に設定したキーを読み、CLI引数へキーを渡さない。

途中失敗ではjournalと予約/結果を保持して止める。journalを削除・編集したりstale lockを機械的に解除して再送しない。不明送信の照合/監査付き解決は未実装なので停止後は原因を確認する。

採点は人/独立AIが項目ごとに行い、輸送成功と回答品質を分ける。正解の人間確認、残りの調整用、未使用20問の別実行入口、full production promptとの照合、実検索/PDF/OCR/iPadは残る。成果物のimmutable model snapshot固定は未実装で、aliasが同じままprovider側更新される可能性も記録する。

切り戻しはrunnerを停止し、private journalを保持すること。今回の新tool/test/docだけを対象とし、productionや既存の未コミット変更は戻さない。

Projectの資料の更新: なし。
