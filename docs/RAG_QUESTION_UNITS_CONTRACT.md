# 質問unit前処理の最小契約

2026-10-15。[v4候補設計](RAG_QUESTION_UNIT_PLAN_DESIGN.md)の第1単位。Standardの評価専用pure moduleとして実装し、資料chunking・出典・本番への接続は行わない。

## 入出力

質問は文字列・非空白・最大16384 UTF8 byte・妥当なUnicode scalar列であること。孤立surrogateや不正型/余剰引数は本文を含まない固定errorで拒否する。入力上限拒否は意味不明判定ではない。

supported時はversion/status/questionHash/unitCount/units/semanticCompleteness/releaseAcceptedを返す。questionHashは元の文字列のUTF8 SHA256、unitsは順にid/start/end/textを持つ。idはu1..u64、start/endはserver管理のUTF16位置、textはその位置の原文そのまま。semanticCompletenessはnot_evaluated、releaseAccepted=false。戻り値は毎回独立したobjectとする。

65個目が必要になればstatus=unsupported、reason=unit_limit、unitCountLowerBound=65、units=[]で止める。部分リスト・切断した質問は返さない。全文やhashの正規化をしない。IDは質問をまたいで同じu1になり得るので、後段は必ずquestionHashと元質問へbindingし、渡されたunitsを信用せず再生成する。

## 境界規則（決定的な規則）

- 区切りは `。！？!?`、CR、LF、Unicode line separator U+2028、paragraph separator U+2029。
- 隣接する区切り文字だけを一まとまりとして直前の内容へ含める。空白を挟めばrunは終了する。例：`A?改行 B! C` は `A?改行` / ` B!` / ` C`。CRLFの間では切らない。ASCII period、comma、semicolonでは切らず、小数点・英略語をこれらだけで分割しない。
- 空白の集合は固定したECMAScript WhiteSpace+LineTerminator（U+0009..000D、0020、00A0、1680、2000..200A、2028、2029、202F、205F、3000、FEFF）とする。先頭・途中の空白/改行だけは独立unitにせず、その後の内容へ含める。末尾に空白だけが残れば直前unitへ付ける。内部の空白・区切りを削除せず、各unitは非空白であること。
- 引用符/括弧内部でも区切り規則は同じ。引用・括弧の対応やURL/数式の構文を理解しているとは主張しない。unitの見た目が自然文の文や句と一致する保証はなく、文脈は元質問全体とunitの順序で保持する。
- Unicode scalarの途中では切らない。結合文字・ZWJのgrapheme境界を保証しない。句読点直後に結合文字がある場合なども正規化や並べ替えを行わず、そのまま保存する。

## 不変条件と検証

supportedでは、最初のstart=0、最後のend=元質問.length、隣のend/startが等しい、全textを連結すると元質問と完全一致、unit番号の連続性、hashの再現性、上限64を確認する。

合成テストで日本語/英数字/改行/CRLF/空白/引用内命令/反復語/emoji/結合文字/ZWJ/上限/不正入力と、決定的な組合せ入力で復元・境界を確認する。既存開発8問は前処理で原文の位置を覆えることだけを確認し、モデルの要求分解や意味精度を評価したとは扱わない。未使用20問は使用しない。

このmoduleは元質問を保持するが、それを事実やsystem指示へ昇格させない。unit IDが実在することだけでは、要求/role/ラベルが正しいとは判定できない。v4各roleの参照上限と表現不能の扱いは後段validatorの小契約で別に確定する。

pure module/テストを追加し、独立コードレビューを通過した。次はrole別参照上限と表現不能の扱いを確定し、v4 schema/validatorを別単位で準備する。API/キー/ログ/保存・本番構成を変更しない。Projectの資料の更新: なし。


## 実装と検証

独立Plannerの指摘を反映してrun/空白優先順位/入力全文検査の順序を固定した。新 `question-units.mjs` と `rag-question-units.test.js` を追加。専用11テスト（決定的な1000組合せ、既存開発8問の注釈位置保持を含む）成功。位置保持は要求抽出の品質評価ではない。独立コード/全Workerの最終結果を後記する。API/キー読取/本番接続0。


## 最終確認

専用11・全Worker1,436成功（失敗/skip0、44.2秒）、独立コード11成功、未解決High/Mediumなし。Lowの文書状態/run優先順位/空白集合は更新済み。1000の決定的な組合せは有効入力の復元と空白のみ入力の拒否を両方確認した。ログ `/private/tmp/studiquo-question-units-all.log`、本文なし結果 [RAG_QUESTION_UNITS_RESULTS.json](RAG_QUESTION_UNITS_RESULTS.json)。構文/差分確認、凍結source hash・4失敗run lock保持を確認。iOS/実モデルは今回未実施。
