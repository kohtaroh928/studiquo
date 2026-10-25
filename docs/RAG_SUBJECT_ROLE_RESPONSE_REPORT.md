# 対象role比較：応答binding

2026-10-16。新12問×baseline/candidateのoffline応答検証を追加した。旧response/parser/runnerは変更しない。

`parseSubjectRoleTaskPlannerResponse(index,variant,observedRequestHash,raw)`は固定requestと実送信contextのhashを照合し、別版hashを応答の復号前に拒否する。variantはモデルの自己申告ではなくlocal context由来。質問/hash/provenanceは固定質問から再生成し、completed/model/usage/単一output/byte/v4形式の検証を維持する。エラーは固定code、補正/fallback/本文echoなし、oracle/review importなし。

同じraw応答は、両版についてそれぞれ正しいlocal contextを呼出元が与えれば形式上は検証できる。requestHashは上流が指示を実行した証明ではなく、trusted callerの版/送信記録の取り違えを防ぐためのもの。この限界もテストする。

対象8件は24模擬出力/28要求、同一質問の版違いhash拒否、質問違い、完了/refusal/usage/byte/JSON/旧契約拒否、誤roleの意味pending、clone独立性を確認。全Worker1,556件/独立コード8件成功、失敗/skip 0。比較設計の独立Planner/安全レビューも最終High/Mediumなし。提出packet ID/hashのarm binding指摘を反映した。[結果JSON](RAG_SUBJECT_ROLE_RESPONSE_RESULTS.json)へ最終hashと結果を記録した。モデル精度改善・実API互換性は未確認。

次は[新有限paired設計](RAG_SUBJECT_ROLE_PAIRED_DESIGN.md)に従う24job journal/replayから進む。baselineの確定した意味不適合は観測対象として残し、技術失敗とcandidate不適合/未知は停止する比較gateを旧gateと分離する。今回API/キー読取0。Projectの資料の更新: なし。
