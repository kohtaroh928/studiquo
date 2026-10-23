# 対象role比較：12問の有限評価完了

2026-10-16。予定していた12問×従来版/修正版の**24送信と4段階の独立意味レビューを完了した**。凍結した要求抽出oracleの範囲では、両版とも12/12がreviewed_match・reviewComplete、missing/extra上下限0。修正版の優位性は確認できていないため、本番prompt v1を維持する。

## 確認できたことと残る差

前半の対象・属性・条件の対応に加え、最後の4問では対象の非捏造、名前に含まれる操作語の誤解防止、無関係な背景の除外を確認した。[最終元監査](RAG_SUBJECT_ROLE_COMPARISON_STAGE3_AUDIT.md)参照。対象不在でもsubjectsを勝手に埋めず、値を尋ねる要求を保持した。

ただし対象不在2問（index8/9）では、両版でcandidateとneeds_clarificationが逆に分かれ、unresolvedの有無にも差が出た。**要求の抽出適合は、聞き返しや回答可能性の判定が正しいことを保証しない。** 凍結oracleはその期待値を定義していないため、今回の合格範囲に後付けで含めない。次の独立した評価項目として保持する。

12pair中8pairはplan全体が同一、10pairはtasksが同一。比較・推薦の2問はラベルや参照表現に差があっても独立意味評価では双方適合だった。表現差だけを改善点や誤りへ数えない。単発実行の少数合成開発問で、一般的な正答率・統計的優位性・繰り返し安定性を示すものではない。旧8問runで見つかった欠落の原因や修正を証明する評価でもない。

## 通信・料金・速度

| 項目 | 最終stage3追加分 | 全24送信 |
| --- | --- | --- |
| 形式完了 / 技術失敗 | 8 / 0 | 24 / 0 |
| input / output tokens | 11,136 / 2,043 | 33,662 / 6,134 |
| reasoning（output内数）| 969 | 2,413 |
| cache write / cached | 11,112 / 0 | 33,590 / 0 |
| usage料金推計 | 0.00241290 USD | 0.00727295 USD |
| 時間中央値 | 3.734秒 | 3.560秒 |
| 時間最短 / 最長 | 2.823 / 7.467秒 | 2.471 / 7.467秒 |

[公式Luna料金](https://developers.openai.com/api/docs/models/gpt-6-luna)を当日再取得し、短文defaultのinput0.10/cached0.01/write0.125/output0.50 USD/百万tokenで推計。cache writeをinputから区分しreasoningをoutputへ二重加算しない。税・地域追加料金・アカウント条件・実請求は未確認で、これはAPIの請求書の確認ではない。全体予約196,608microUSDは実請求上限や請求額ではない。

24送信の時間合計93.176秒は送信ごとの保存開始までの合計で、レビュー待ちや保存同期を含む全作業時間ではない。RAG検索・回答全体の時間でもなく、版間の速度優位性も評価していない。

## 安全・検証・引き継ぎ

stage2/3それぞれの専用entryで、先行元reviewのhash/replay・manifest/source・固定run状態を確認し、実fetch直前にも該当ordinal順・stage・本文hash・endpoint/POST・最大8を制限した。entry構文/mockと独立安全確認後だけ送信した。再試行・別run救済・過去entry再実行なし。最後の元reviewも固定監査文書hashと照合してprivate artifactへ登録し、journalで全4段階を再採点した。

最終状態はstage4/done、予約/完了/review各24・比較12pair、generationComplete/allReviewsComplete=true、baselineMismatchCount=0、candidateAllMatched=true。本番採用を表すreleaseAcceptedはfalse。continueは有限比較gateの結果であり追加送信や本番採用の権限ではない。全entryを再実行しない。

実キーは既存loaderから非表示で取得。本文やキーを共有ログへ出さず、実学習内容は使用していない。旧5停止lock/停止journal、本番v1、未使用20問を保持。コード/DB/設定・deploy/migration/push/merge変更なし。コード不変のため全Workerテストは再実行せず、前工程1,659成功は前工程の結果として区別した。今回は実API・source/保存replay・独立意味/安全監査・entry mock・文書差分を検証した。

人間gold、strict blind/本人性認証、計算のoperand/演算、質問履歴、検索・回答生成・OCR・100ページPDF・iPadの総合品質は未完了。次は追加APIを開始せず、質問の対象不足をいつ聞き返すべきかの期待値を、質問文・会話履歴・指定scopeの情報に照らして別契約へ整理し独立レビューする。資料の根拠不足や検索0件と質問自体の曖昧さを混同しない。今回の凍結oracleや監査文書を書き換えない。

[全結果JSON](RAG_SUBJECT_ROLE_COMPARISON_STAGE3_RESULTS.json)、[stage2](RAG_SUBJECT_ROLE_COMPARISON_STAGE2_REPORT.md)。Projectの資料の更新: なし。
