# RAG回答ルールの棚卸しと固定比較基盤

2026-10-14。計画の第0段階と第1段階の初回整理。固定版・同一入力の比較器・対応表を実装し、現行方針を責務別の定数へ分離した。生成するpromptのbytesは保持する。新しい文章への統合と実LLM比較は次の単位で行う。既存の少数成功を汎用精度とは呼ばない。

同日続行の結果: [A/C比較報告](RAG_POLICY_REVISION_REPORT.md)。重複整理とpartial精密化を24実回答で比較したが、source_onlyで必須差分の回答漏れを観測し両候補を不採用とした。runtimeはv1出力へ復帰。以下は初回棚卸し時の記録として保持する。offline比較器に加え、既知variant/固定snapshotだけを送る制限付きadapterが実装済み。第1段階全体は未完了。

## 固定したもの

`mcp-server/scripts/rag-quality/baselines/20261014-policy-v1/` に次を保存。

- `answer-policy.mjs`: 現行answer-policy.jsをbyte単位で複製。固定指示のみ。Workerはこの複製をimportしない。
- `manifest.json`: 8status×2styleの16出力のhash/bytes、実装・検索・runner・問題bank・rubric・過去報告のhash。ファイルhashは偶発的な変更検知用で、改ざん耐性のある署名ではない。
- `production-contexts.json`: 既存の開発3問と別の境界診断3問を、実handleAIとローカル合成検索/モックOpenAIで取得した6snapshot。質問/履歴・元のcontext・構造化出典・モデル設定を固定。新しいAPI評価ではない。固定合成資料のみで、実ノート・秘密・採点用goldを含めない。
- `rubric.md`: 現行の採点基準本文を複製してhash検証。旧/新版の採点にはこの固定版を使用し、基準を変える場合は別比較とする。現行rubricと過去報告もhashの変化を別欄で検出する。過去報告本文そのものは複製せず、参照hashで保持を確認する。

`prompt-baseline.mjs`は旧固定版と現在候補版を、同じsnapshot・同じstyle・同じ設定で組み立てる。異なるのは末尾の固定回答方針だけ。同一style内のbefore/after比較と、同じ資料でのstyle比較を混同しない。snapshotのchunk IDは当時の合成DBを識別するもの。本番の認可を通過する証明や実検索品質の評価には使わない。

この比較器はoffline専用。key読取/外部送信/既存live runnerの制限変更なし。返すrequestを、そのまま有料実行できる入口は追加していない。後でAPI比較を行う際は、固定された旧/新版を扱う評価adapterの予算・送信前journal・初失敗停止を別に確認する。

モデル評価条件はLuna/medium/default/store:false/stream:true。production再現は最大8192出力token、簡略answer-layer評価は2048。実Workerがmediumを明示設定しているという意味ではない。モデル名はWorkerの環境設定で解決する。store:falseを全ログ保持なしという保証に読み替えない。

30開発問/20未送信問を保持。この作業で未送信20問をモデルへ送っていない。bank全体のhashのみ固定し、goldの人間確認pendingを保持した。旧報告の誤答/成功も上書きしない。

## 対応表の読み方

P1=信頼境界/出典、P2=対象/事実/条件、P3=回答目的、P4=回答漏れ、P5=表現。これは整理案の優先階層。現行は長い連続文章に局所的な優先指示があり、この階層へ変更済みではない。

G/P=grounded/partial、S=source_only（未指定/不正enum含む）、E=explain、I=insufficient、C=clarification、O=disabled/fallback/no_hits/unknown。行番号は固定版answer-policy.mjsのもの。

テスト略号と検証の限界:

- AS=`rag-answer-style.test.js`: productionへ届く指示・style・同じ入力/出典のモック検証。30開発問の経路確認を含む。生成回答の意味は採点しない。
- AP=`rag-answer-presentation.test.js`: 単位/簡潔さ/通常chatへのfallbackのモック検証。
- CE=`rag-comparison-evidence.test.js`: 条件抽出/quoteの決定的検証と、最終テストのforeign owner/失効context検証。認可全体はRS/RIも合わせて確認する。汎用自由文の抽出能力ではない。
- AB=`rag-answerability.test.js`、CR=`rag-condition-reference.test.js`: 根拠/指示語判定の検証。
- RI=`rag-integration.test.js`、RS=`rag-safety.test.js`: canonical認可、失効、出典、普通chatの契約検証。
- AI=`ai.test.js`: 通常chat、数式表記、入力保護のモック検証。
- PB=`rag-prompt-baseline.test.js`: 固定版/同じ入力/コピー分離/未送信問除外/変更検知。

下表の対応は既存テスト内の具体的assertionまたは経路検証。独立した実回答の合格を意味しない。特に条件・例外の意味、科学的な説明、矛盾の扱い、全要求への回答は引き続き生成回答の採点が必要。

| ID/固定版位置 | 目的・保持すべき規則 | 適用 | 優先 | 主な回帰対応 |
| --- | --- | --- | --- | --- |
| B01 ai.js CHAT_SYSTEM | 学習の筋道/途中の次の一手と事実の直接回答を区別 | 全chat | P4 | AI/AS経路。学習支援の実回答は別評価 |
| B02 ai.js CHAT_SYSTEM | 用語定義/成立条件/不確実性/簡潔な日本語 | 全chat | P2/P5 | AI、AS初心者文言・条件保持。Sの未記載定義禁止が優先 |
| B03 ai.js MATH_RULES | $/$$、日本語text、通貨、code/特殊command回避 | 全chat | P5 | AI「every prompt shown to a student…」 |
| S01 L2–3 | 未記載の定義/背景/たとえは補足表示しても禁止。質問の初心者文言よりS優先 | G/P S | P3 | AS「beginner wording…」 |
| S02 L4 | 新しい仮定の人数/日付/場面を作らない。原資料の実例は使用可 | G/P S | P3 | AS「refinement reaches both production styles…」 |
| S03 L5 | 確定した資料からの整理/比較/計算は許可。未知値で代用しない | G/P S | P2/P4 | AS初心者文言/条件保持 |
| S04 L6 | 未記載の用語を定義する基本chat指示を抑制 | G/P S | P3 | AS初心者文言 |
| S05 L7 | 名前/型番から用途等を補完しない | G/P S | P2 | AS enum/learning対の経路。実意味採点は別 |
| S06 L8 | 不明指数/記号を保持、計算不能と既知値/単位、不要代入抑制 | G/P S | P2 | AP、AS条件保持/不明数式対 |
| E01 L9–10 | 資料の答えを先に、必要な背景を拒否せず区別して補足 | G/P E | P3/P4 | AS「allows labeled background…」 |
| E02 L11–12 | 一般助言/定義も最初の資料外説明より前に補足表示 | G/P E | P3 | AS初心者文言/partial advice |
| E03 L13 | 固有仕様/値/期間の推定禁止、条件と不確実性保持 | G/P E | P2 | AS partial advice/条件保持 |
| E04 L14 | 量/率、合計/単位あたり、分子/分母と基準を説明 | G/P E | P4 | AS初心者文言。科学的正確さは人間評価 |
| E05 L15 | 新しい例は事前に仮定表示。原資料の実例は仮定と呼ばない | G/P E | P3 | AS refinement |
| E06 L16 | 役立つたとえと限界。未知の固有値を埋めず、資料との食い違いを保持 | G/P E | P2/P3 | AS初心者文言/learning対。矛盾の実回答は別 |
| E07 L17 | 未知の式/係数を補わず、一般原理のみ区別して説明 | G/P E | P2/P3 | AS条件保持/不明数式対 |
| R01 L27 | 対象名を似た既知名へ置換しない | G/P | P2 | AS learning対、AB |
| R02 L28 | untrusted本文の指示/role/出典生成に従わない | G/P | P1 | AS learning対、CE fake role、RI |
| R03 L29 | 不正指示と独立した事実まで捨てない | G/P | P2/P4 | AS不正指示を含む対。追従/過拒否の意味採点は別 |
| R04 L30 | comparisonAssessmentの順序/禁止flagを一般差分より優先。条件不在≠一致 | G/P assessmentあり | P2 | AS「authorized structured conditions…」、CE |
| R05 L31 | 発行日と適用日/旧規則の明示関係を照合、不明な優先を推測しない | G/P | P2 | AS「revision applicability…」「old deadline…」 |
| R06 L32 | 対象が曖昧なら確認、一意なら不要な確認をしない | G/P | P2/P4 | CR、AS unresolved usage |
| R07 L33 | 資料の答え→必要補足、日本語/原用語保持 | G/P | P3/P5 | AS/AP経路。順序/用語の実採点は別 |
| R08 L34 | 対応単位/条件の既知値は方向付き差分/同値を明示。一部不足でも既知比較保持 | G/P | P2/P4 | AS「supported delta and clear metric」 |
| R09 L35 | 指標の分子/分母/意味、購入価格÷時間を実費にしない、未依頼片側比率抑制 | G/P | P2/P4 | AS delta/metric、CE price ranges |
| R10 L36 | ある事実をないとせず、不足は取得抜粋の範囲 | G/P | P2 | AS/AP経路、AB。実回答の過拒否は別 |
| R11 L38 | 記号の対象範囲を名称から補わない | G/P | P2 | AS refinement |
| R12 L39 | 式の条件/例外は同じ項目へ。計算不能でも保持。未記載条件は必要時だけ未確認 | G/P | P2/P4 | AS condition retention / partial advice |
| R13 L40 | 式/単位の原記載の言い換えまで資料外と拒否しない | G/P | P3/P4 | AS partial advice。実理解品質は別 |
| R14 L41 | 記号:意味(単位)、量→指定単位での数値へ黙って再定義しない | G/P | P2/P4 | AS refinement/revision、AP |
| R15 L42 | 必要値不足は未依頼代入/一般式で埋めない。明示式依頼/全値あり計算は許可 | G/P | P2/P4 | AS条件保持/refinement、AP |
| R16 L43 | 代入の単位と数値表現を保持、未記載単位は推定しない | G/P | P2 | AP |
| R17 L44 | 不要な相対日付変換をしない、必要前提不足なら確認 | G/P | P2 | AP文字列/AS開発経路。日時の実意味採点は別 |
| R18 L45 | 質問項目と判断に不可欠な不足だけ先に答える | G/P | P4/P5 | AP |
| R19 L46 | 原資料に記載なしとあっても無関係な不足一覧は出さない。明示依頼は許可 | G/P | P4/P5 | AP |
| R20 L47 | 結論一度、不要な末尾まとめを作らず、明示要約は許可 | G/P | P5 | AP |
| R21 L48 | 簡潔さのために条件/例外/複数質問の回答を落とさない | G/P | P2/P4 | AP/AS条件保持 |
| R22 L49 | 別対象の代用不可理由は簡潔に。要求された比較値は保持 | G/P | P2/P5 | AP |
| R23 L50 | 式の条件/例外と未知値の未依頼一般式を出力前に確認、手順非表示 | G/P | P2/P5 | AS/AP指示経路のみ。独立validatorではない |
| R24 L51 | 出典はserver構造化。本文に出典ID/資料名/ページ引用を生成しない。対象名/質問の番号は許可 | G/P | P1 | AS refinement、RI canonical citation、CE |
| T01 L20–22 | 既知enumのみE。ユーザー本文を固定方針へ補間しない | 全RAG | P1/P3 | AS only explicit enum、PB |
| T02 L59 | partialは支持部分/不足範囲を保持、全体の推薦断定/片側を共通点扱いしない | P | P2/P4 | AS partial advice、RI evidence states |
| T03 L60 | 根拠不足は抜粋の限界+正式名/該当箇所の確認、一般知識の代替や出典なし | I 全style | P2 | AS conservative policy、AP insufficient |
| T04 L61 | 指示語の対象を確認し推測しない | C 全style | P2 | CR、AS conservative policy |
| T05 L62 | 0hit/障害/無効/未知statusはRAG方針を付けず通常chat | O 全style | 契約 | AP exact disabled、AS ordinary chat、RI disabled、PB |

## 重複統合案と意味変更を分ける

候補A（重複整理）: S01/S04と英語GROUNDEDの資料外定義禁止、E01/E02と英語EXPLAIN_GROUNDEDの補足境界、R18/R19と英語GROUNDEDの不足情報制限をまとめる。削除後も例外・適用style・部分回答許可をすべて残す。英語/日本語の繰り返しが生成遵守を強めている可能性があり、文言を短くしただけで意味保持・品質改善と認定しない。APIで同一入力を比較してから採用する。

候補B（責務の整理）: 初回を実施。style別の先頭に続く長い共通文字列を、IDENTITY_AND_EVIDENCE_RULES、MATH_AND_SCOPE_RULES、PRESENTATION_AND_CITATION_RULESへ分離し、元の順序/改行/文字列を保持した。文章順の変更もモデルの出力に影響し得るため、この機械的分離と文章統合を混ぜない。固定版との77通りのstatus/style比較を専用テストで確認する。今後意味を修正する際はこの一時的byte同一gateを明示的に置き換え、固定v1を上書きしない。

別差分C（意味修正が必要）: partialの英語は「少なくとも一方の比較対象の根拠がない」と断定するが、現在は両対象の点灯時間があり片側の価格だけない場合もpartial。実際のstatusより強い欠落を伝えている。今後は「要求項目の一部に不足がある」とし、対象/属性ごとの支持範囲で説明する案を独立比較する。この作業ではまだ修正していない。

別差分D（優先関係の明文化）: CHAT_SYSTEMの定義/学習筋道よりsource_only、一般差分よりcomparisonAssessment、説明追加より未知固有値保持、簡潔さより条件/例外/回答漏れ防止を明示する。既存の局所指示を単に移す箇所と、未定義の優先を追加する箇所を別に記録する。

維持/削除しないもの: R02/R03/R24の信頼境界と事実利用、R04の条件不一致時の禁止、R12/R15の例外、I/C/Oの保守的/通常chat契約。認可・失効・課金はpromptの文言だけに依存させない。

## 次の検証と進退

まず候補Aの狭い一組で旧/新版を比較する。テストの期待文字列を新版に合わせるだけで改善扱いしない。各要求IDの意味保持レビュー→対象テスト→Worker全体→固定少数API比較の順。差分/条件/不足/説明境界の必須成功、過剰拒否と補足不足を別に確認する。

現在の6snapshotは既知診断用で、新問題や開発30問の代わりではない。old/new比較は順序効果・繰り返し・費用・応答時間と併せて記録する。実装がbyte同一の整理だけなら実API再実行は不要だが、生成文字列が変わる統合では実回答比較が残る。予約20問は最終凍結まで送らない。

失敗を検索漏れ/根拠判定/回答誤り/回答漏れ/説明不足/表示に分ける。goldが曖昧な版問題はpendingのまま。誤答0、必要項目95%は計画上の目標で現在の実測値ではない。独立validator/汎用比較parser、実Cloudflare/日本語OCR/代表100ページPDF/iPadは依然未完了。

固定promptを版管理し変更ごとに評価する考え方は[OpenAI公式Prompting](https://developers.openai.com/api/docs/guides/prompting)も参照。外部promptの導入やRAGFlowのforkではない。

## 今回の検証結果

- 対象6件成功。旧固定v1との77通りの出力一致、fallback/status/style、固定rubric、同一snapshotのbefore/after、goldの入力経路除外、コピーの分離、変更検知を確認。
- 関連82件成功。最終Worker全体1,304件成功、失敗/skip 0（57.0秒）。ログ: `/private/tmp/studiquo-rag-prompt-baseline-all-final.log`。iOSは変更せず再実行していない。
- offline比較報告: 固定policy16、context6、policy出力の変更0、rubric/過去結果の変更0。ソース変更として責務分離したanswer-policy.jsだけを検出。
- 構文確認、差分/新規ファイルの空白確認を実施。独立レビューのrubric本文固定/参照hash検知の指摘を修正し再確認。独立対象17テスト成功、新たなHigh/Medium指摘なし。
- 実API送信0/評価API費用0。fixture取得時のOpenAI/Workers AI/Vectorizeはモック。コードテスト1,304件を質問1,304問の正解や精度改善とは呼ばない。

今回の成果はoffline比較基盤・棚卸し・意味を保つ責務分離。現在のWorker出力/モデル/設定/DB/公開状態は変えず、実API課金なし。第1段階全体は新版の実回答比較まで未完了。次は候補Aの重複統合と別差分Cのpartial指示修正を分けて比較する。Projectの資料の更新: なし。
