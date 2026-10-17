# 修正3問のproduction prompt実OpenAI確認

2026-10-14。APIキー・費用上限を扱う評価tool変更をHighとして独立設計・コード・安全レビューする。合成資料の調整用3問のみ、6回答を計画。bank/正解は変更しない。

## 方法と受け入れ条件

固定 `e50-versions-01` / `e50-pages_tables-02` / `e50-partial-03` をローカル `handleAI` に通して全production基本prompt・原文context・検索後status・style方針を捕捉する。同一索引snapshotでstyle間の入力、方針前のprompt、本人DBに対応するsource/page/chunk出典を確認する。任意資料・任意body・未使用問題の入口は作らない。

捕捉は合成キーとSQLite、模擬Workers AI/Vectorize/OpenAIで行い、実キーやHTTP headersを保存しない。登録された不透明handleだけが送信bodyを返し、複製後の変更は内部bodyへ影響しない。全6件を検証してから実キーを読み、固定OpenAI Responsesへ送信する。実モデル回答と検索前段の検証を分離する。

productionの出力上限8192tokensは維持し、評価時だけmedium/defaultを明示する。思考tokenも出力上限に含む。モデルLuna、store=false、tools/previous_response_idなし、24KiB body上限、32768入力tokensの保守予約。1件8192 microUSD、6件49152 microUSD（0.049152米ドル）の予約、directory予算0.50米ドル。入力予約は厳密なtokenizer/請求保証ではない。

料金は [公式Lunaページ](https://developers.openai.com/api/docs/models/gpt-6-luna) を当日再確認し、既存runner設定の保守料金を維持した。確定請求とは区別する。

## 永続記録と失敗

既存E50の0700directory/0600journal、hash連鎖、排他lock、送信前reserved+fsync、usage/model/completed検査、失敗時停止を再利用する。最初のエラーで後続送信・内部retryを止め、予約を返さない。60秒は応答本文読取まで、通信全体6分の制限。

今回のCLIは既存directoryをcaptureと秘密読取前に拒否する。再索引でrandom chunk IDが変わるため、別processでのcapture再開は実装しない。送信不明や失敗後は元journalを保持して監査し、別directoryによる暗黙の再送を行わない。生成回答の生データはprivate journalのみへ保存し、repo/Notionは結果metadataと所見だけにする。hash連鎖は耐改ざん署名ではない。

## 実行結果

全6送信・6完成、失敗0。同一固定directoryのjournalへ送信前予約と完成回答を保存した。Lunaを返却modelでも確認。料金問題の両styleは1,500円、時刻表の両styleは北行き8:20・300円、比較の両styleはEの既知価格を保持しFの価格不明/お得さ未確定を示した。

Codexと独立AIが全6回答を確認した。料金の金額・開催日基準、表の方向/時刻/料金、不明価格とお得さ未確定の主要要求項目は合格。比較の両回答はE5時間/F7時間を列挙したが、要求項目の「Fが2時間長い」を明示しなかった。これは数値誤答ではなく、要求された比較差分の説明不足2件として残す。全項目合格にはしない。教師/人間による確認は未完了。

explainの追加指標320円/時間は資料の既知値からの正しい計算で、背景説明や仮定例の表示違反とは判定しない。一方、「購入価格÷記載の点灯時間」という指標と実際の使用費用の違いが明示されておらず、指標説明の改善・人間確認候補として残す。資料が利用料金/電気代を記載しているという意味にはできない。

入力21,351、出力585（うち思考310）、合計21,936tokens。1.237〜4.443秒、平均約2.529秒。通常入力を全てuncached Standardとして見積もると0.0024276米ドル。cached割引/実請求/キーの組織は未確認で、確定請求ではない。予約額0.049152米ドルは全額保持。本文なしmetadataは `RAG_PRODUCTION_API_RECHECK_RESULTS.json`、回答はprivate journalのみ。

Worker全体1,284件、関連runner15件成功（失敗/skip 0）。独立コード・安全レビューでHigh/Medium指摘なし。秘密を外部CLI引数や成果物へ記録しない。capture中の例外/未知URLによるfetch復元はfinallyを読取確認したが、失敗注入テストは未追加の軽微な残件として記録する。

## 対象ファイルと残件

追加: `evaluation-50-production.mjs`、`evaluation-50-production-live.mjs`、`src/rag-evaluation-production.test.js`、本報告。変更: `evaluation-50-live.mjs` の評価専用production分岐。通常のminimal E50経路・本番Workerコードは維持する。

この評価は実Cloudflare検索/PDF/OCR/iPad、実認証や課金counter、実API後のproduction再認可/ストリーミングまで通る検証ではない。元の曖昧な締切問題、人間の正解確認、未使用20問、実検索/実機は残る。停止・切り戻しは評価toolのみを対象にし、private journalと既存の未コミット変更を保つ。deploy/migration/secret設定変更なし。

次は比較差分を明示する回答指示と、価格を時間で割る場合の指標の意味を局所的に改善し、別属性/別対象の回帰を確認する。良い回答だけを選んで再集計せず、今回の6回答と指摘を保持する。

後続の修正と新しいrun02で、比較差分の明示と未依頼の片側指標の抑制を確認した。元のrun01結果は保持する。[比較差分の修正報告](RAG_COMPARISON_DELTA_FIX_REPORT.md)を参照。

Projectの資料の更新: なし。
