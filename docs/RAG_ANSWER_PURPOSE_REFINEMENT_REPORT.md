# 回答目的の再調整（v2）

日付: 2026-10-11。作業先: .worktrees/rag-wip / codex/rag-wip。ローカル実装、未公開。

## 問題と修正

通常チャットで共有された最初の対では、source_onlyも資料外の基本概念を補っていた。元の評価基準も「資料の事実として説明しない」としか書いておらず、補足と表示した背景を禁止する意図が曖昧だった。今回は固定指示と採点基準の両方を修正した。

- source_only: 初心者向け・意味・具体例を求める質問でも、未記載の定義・背景・たとえ・仮定例を追加しない。「資料外の補足」と表示しても追加しない。求められた定義や理由だけを取得抜粋で未確認とし、他の既知項目は答える。資料の既知値からの計算・比較は許可する。
- explain: 必要な背景補足を資料と区別して保つ。量と率、合計と単位あたり、割合の分子/分母、時間/比較の基準を省かない。たとえは必要な場合に条件と限界を示す。固有の未知値、条件、読めない式は補完しない。

分野や特定問題の数値をproduction指示へ追加していない。質問や資料本文からstyleを推測せず、既存enumで選択する。insufficient/clarificationの方針、検索/出典/認証/同意/API形式/iOS/flagは変更なし。通常チャットのリクエスト互換を維持。未指定と明示source_onlyは同じ修正後方針になるが、grounded/partialの旧資料回答指示は今回の不具合修正により変わる。過去報告のbyte一致は当時の検証であり、今回の旧policyとのbyte一致ではない。

## 変更ファイル

- mcp-server/src/rag/answer-policy.js（固定方針）
- mcp-server/scripts/rag-quality/learning-fixture.mjs（rubricの修正、平均値と予約条件の新規2組）
- mcp-server/src/rag-answer-style.test.js（production経路で初心者向け質問がsource_onlyを上書きしない回帰2件、追加probe2件）
- docs/HYBRID_RAG.md（現行方針の追記）
- docs/RAG_ANSWER_PURPOSE_REFINEMENT_REPORT.md（本書）
- output/rag-answer-purpose-v2/（合成6組12プロンプト、手順、採点項目を別ファイルにしたmanifest）

元の4組の質問/資料は保持し、採点基準を修正。新規2組は情報不足を資料中へ明示するヒントを入れていない。設計時に内容を見たprobeでありblind holdoutではない。promptにはmanualChecksを含めない。manifestの両styleは同じinputHashで、質問/資料が同じことを確認した。

## 検証

- 対象3ファイル37件成功、失敗/skip 0。追加4件を含む。
- サーバー全1,124件成功、失敗/skip 0。新規2組の不足ヒント削除後は対象37件を再実行し成功。
- JS/module構文、git diff --check成功。
- 同じindexed snapshotで両styleの質問/context/出典が同じ、source_onlyの新制約をGemini systemInstructionへ渡す、explainには背景禁止を混ぜない、計算禁止にしない、partial不足を保持、未知enumの安全なdefault、本文の偽styleの無効、採点基準の非送信、RAG無効/同意なし/0件/障害の通常リクエストを確認。

モックの返答はsynthetic answerであり、実際のLLMが新指示に従ったことを証明しない。今回API課金呼出・実資料送信・deploy・migration・push/merge/commitなし。iOS変更なしなのでiOSテストは再実行していない。少数の共有回答や指示の自動検証を汎用精度へ換算しない。

## 次の実回答確認

まず01回路のsource_only/explainを同一モデル・同一思考量の新規チャットで比較。以前ユーザーが伝えた思考量は中程度、現在の設定は別途確認する。source_onlyで資料外説明が消え、explainで必要な定義と未知値保持が残るかを採点する。次に05平均値で計算拒否や量の混同がないか、06予約条件で例外と未記載理由の非推測を確認する。02不明指数/不正命令、03不要な不足一覧、04根拠不足も回帰する。

実APIで同一資料・質問・検索snapshotを使う対、未使用問題、複数回、モデル/思考量/待ち時間/費用を記録する。固定参照の通常チャットはsystem role階層や実検索を再現しない。iPadでの目的選択UIはまだ未実装で、現アプリは未指定defaultを使う。W61/W03/W59〜W66は実回答再確認待ち、完了にしない。

停止: explain指定を外せば資料確認へ戻る。新source_only指示に問題があれば本工程の固定指示だけを戻し、認可/資格/削除基盤は戻さない。両RAG feature flagはfalseを維持。

Project資料の更新が必要: HYBRID_RAG.md（複製は未変更）。
