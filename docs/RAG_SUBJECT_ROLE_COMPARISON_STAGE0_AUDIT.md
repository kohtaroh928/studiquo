# 対象role比較：stage0 独立意味監査

2026-10-16。中立packet 2件だけの原質問・実plan・構造参照・oracleと、8観点semantic仕様を確認した。private job mapping、variant、指示本文、期待する候補改善結果は参照していない。合成fixtureのmock判定は使用していない。追加API・キー読取・既存source変更・登録操作なし。

両packetを個別に確認した結果、各2要求は現契約でrepresentable。各packetで t1→r1、t2→r2 を承認する。対象概念をsubjectsに分離し、求める成立条件と例外をattributeへ保持している。質問は条件や例外を尋ねており、答えを限定する別の適用状況を指定していないため、conditionsが空であることも妥当。両要求を1taskへ結合せず、追加の値要求や比較へ変えていない。

各packetの全task×requirement（2×2）を次のように確認した。

| 対応 | operation | attribute | subjects | conditions | intent | scope | provenance | noInventedDetails |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| t1→r1 | pass | pass | pass | pass | pass | pass | pass | pass |
| t2→r2 | pass | pass | pass | pass | pass | pass | pass | pass |
| t1→r2 | pass | fail | fail | pass | fail | fail | pass | pass |
| t2→r1 | pass | fail | fail | pass | fail | fail | pass | pass |

交差pairは求める属性と対象が別要求であるため対応しない。操作の種類と条件の空配列は両要求に共通し、質問内にある概念自体を捏造したものでもないため、その観点はfailへ広げない。唯一のunitが原質問全体を含むため、原文箇所の構造的参照は可能である。unitの存在だけで意味対応を承認せず、各ラベル・対象・scopeを原質問と照合した。resolution/evidenceSupport/comparisonPermissionはunknownを維持している。

既存helperによる整合確認は両packetともreviewed_match / reviewComplete=true、承認・可能matchingとも2、missing/extra上下限0。これは提出された独立reviewの集計であり、helperが意味を自動判定した結果ではない。同じ判定内容でもpacket ID/hash別に提出する。armや比較継続の登録判断は親側の凍結mappingとgateで行う。

原oracleの人間確認はpending。既知の合成開発問1pairの要求抽出だけの評価で、検索・回答生成・OCR・PDF・iPad・本番採用・汎用精度の合格ではない。今回の質問は単一unitであり、複数unit参照品質も評価していない。版名は見ていないが、既存の開発文脈からの推測や同一OS環境を排除した厳密blind認証ではない。role名・hashは本人性や独立性の暗号学的証明ではない。

- packet export SHA256: fb028c716a4f965b0a9b8c775442d628a7f00a518d2eab5bef1daad57a0df213
- stage: 0
- completedRequests: 2
- checkpointHash: bfb6beab2a6fbc42a8879757fbfe1f9d0747aa5a49743bb8216650e959a72f36
- manifestHash: 3be1b351bb6f7c9787415ea568e3710b0bc2dde17396cdec6285b8a81a100744
- runId: b0fc8f2f-cda7-4aa7-afd4-ca8d2bab73fd
- packetId: 46507a3c-54d9-4285-a105-411de880967e / packetHash: 29ef35649930135805e5d8b8ece5b95401b1a1df185c3f1cd29afc5f55050f61 / questionHash: aabe2854ff60e03cf6d879c4d932cde4c3f7c01d4ac100260e9c0e461b9e145f / planHash: 642ce8d4ddfe5994e1876d245acbc531443256990044af71509ed3c3bf83986b / oracleHash: 503320956e77b6ab2f12ee398ea84550a963469ce8bdf6263920a8352c47968c
- packetId: d5df119c-3b06-47e7-b7cd-e599c0d9d475 / packetHash: 0cd0d41184981dc1412f5cca264b27a7cc814672619ccdeaafd6a66a711d6368 / questionHash: aabe2854ff60e03cf6d879c4d932cde4c3f7c01d4ac100260e9c0e461b9e145f / planHash: 642ce8d4ddfe5994e1876d245acbc531443256990044af71509ed3c3bf83986b / oracleHash: 503320956e77b6ab2f12ee398ea84550a963469ce8bdf6263920a8352c47968c

原質問・plan全文・quote・offsetを共有文書へ転記していない。保存後の本監査文書は変更しない。Projectの資料の更新: なし。
