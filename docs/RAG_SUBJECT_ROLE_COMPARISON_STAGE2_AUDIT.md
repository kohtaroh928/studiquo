# 対象role比較：stage2 独立意味監査

2026-10-16。中立packet8件の原質問・実plan・構造参照・oracleを個別に確認した。private mapping・variant・指示・期待改善結果を参照せず、mockBatchやテストfixtureの採点をimportしていない。追加API・キー読取・登録・既存source変更なし。

| packetId | 根拠と確認scope | 対応 |
| --- | --- | --- |
| 002d32ac-235d-47b1-95aa-7ec765b212bb | 両資料の同一scopeを共同要約する1要求 | t1→r1 |
| 22cecce0-3d96-43dd-954b-78b82e519450 | 両対象の速度比較と環境条件を保持。英訳ラベルは原文と同義 | t1→r1 |
| 39fc8279-dccf-4650-a17d-ab8fa9805d68 | 両資料の同一scopeを共同要約する1要求 | t1→r1 |
| 4d5eef54-b0d1-4cf1-ade0-ab3819c92201 | 候補2対象の選択推薦と設置条件を保持。無関係な背景を除外 | t1→r1 |
| 5ce1cf93-8625-4b99-acd7-8c5621bd5aaf | 候補2対象の選択推薦と設置条件を保持。無関係な背景を除外 | t1→r1 |
| 64b70a03-2e8c-460e-83c9-9df52df1db4a | 計算操作・求める比・明示対象の対応を保持。operand計算は未採点 | t1→r1 |
| 9ebe5326-1d52-4f4d-a2d3-dae0fffd37c9 | 計算操作・求める比・明示対象の対応を保持。operand計算は未採点 | t1→r1 |
| c8f04bf3-cc95-4994-b0d0-18521b0dbf1c | 両対象の速度比較と環境条件を保持 | t1→r1 |

各packetの全task×requirementは1×1で、計8pairを確認した。operation / attribute / subjects / conditions / intent / scope / provenance / noInventedDetails の8観点を各pairでpassと判断し、全要求は現契約でrepresentableとした。

比較の2packet：比較対象を前文のu1、求める速度と環境条件・依頼を後文のu2へ対応させる。両対象を一つの比較要求に保持し、環境をsubjectsへ混入しない。片方のラベルは英語だが、対象識別子と速度・環境の意味を保った同義表現である。現規約は解釈ラベルの言換えを許すため、言語差だけで不合格にしない。比較の成立・優劣・性能を確定したものではなく、comparisonPermissionはunknownのままである。

計算の2packet：明示対象はu1、求める比と計算依頼はu3で、入力値があるu2を別対象や適用条件に分類していない。供給値は原文provenanceに残るが、taskからoperandの対応を抽出できた、演算方向が定まった、計算が正しいとは判定しない。operandの意味保持・演算・数値結果は元oracleの評価対象外であり、この限定された要求抽出の8観点passから計算能力へ外挿しない。

推薦の2packet：u2の候補両対象とu3の設置状況をsubjects/conditionsへ分け、u1の受付・用具等の背景名詞を追加していない。attributeに設置状況や対象種別を含むラベルも、原質問にある選択scopeの言換えであり、subjectsとconditionsの構造も保持している。実際のおすすめ製品や適合性を断定したものではない。

共同要約の2packet：u1の両資料をsubjectsに保持し、u2の同一手順scopeを1taskでまとめる意図を保つ。資料ごと・文ごとの不要な分割、比較操作の追加、対象の片側欠落はない。

全packetでrequestUnitIdsは依頼文を参照し、構造参照は該当する原文unitへ対応する。unitの実在だけで意味を承認せず、各ラベル・role・原質問との対応を確認した。質問外の対象・状況・値・解答の追加は見られず、支持・解決方法・比較許可のunknownを維持する。

helperで提出判定の整合を確認し、8件ともreviewed_match / reviewComplete=true、各承認・可能matchingは1、missing/extra上下限0となった。helperは意味の自動判定器として使っていない。同じ判定内容でもpacketごとにID/hashを束縛して提出する。

4合成開発問の要求抽出だけの評価で、人間gold確認はpending。複数unit参照を含むが小標本であり、全質問・未知文型・演算・推薦の正しさ・要約回答品質の保証ではない。検索・回答生成・OCR・100ページPDF・iPad・総合RAGや本番採用の合格を示さない。版名を参照しない監査だが、既存文脈や同一OS環境を排除した厳密blind認証ではない。hash/roleは本人性・独立性の暗号学的証明ではない。

- packet export SHA256: a732d5713d5df2d62520ff82d64f62e4b98b301776f46f17b73311c5766bff41
- stage: 2
- completedRequests: 16
- checkpointHash: 6f7007aeca420b81b81f5186401506d9713f3e47ae91c516db3ef00213fe1a87
- manifestHash: 3be1b351bb6f7c9787415ea568e3710b0bc2dde17396cdec6285b8a81a100744
- runId: b0fc8f2f-cda7-4aa7-afd4-ca8d2bab73fd
- packetId: 002d32ac-235d-47b1-95aa-7ec765b212bb / packetHash: aad9805bbc039e24312fa78ca2776640861ad5a4679001127a252f1a4fc5a875 / questionHash: ebd61004fae23b674b3a27c9e45b95a78730c8fe758b4428459d05dceb6b5877 / planHash: 2a8e62223ae110cfc0c75c2fbaf4beaac347bb2f478c17813d7a8851f44b704f / oracleHash: 6095c976f21a98c9f9ea2f49028b5823e9c262e4a54ea3803b740a0ea3166ba5
- packetId: 22cecce0-3d96-43dd-954b-78b82e519450 / packetHash: 44bbfc1502eeb1e0e1bb5476254a88f3e2369afe0793be94dc282329a6040af7 / questionHash: 9095ac8eebccb2eca75ffd189ccad24be49dbbfd62e8beb35a441751a3c1d5b0 / planHash: ebe00687585c4b9c51a81306c7d6f19bd16a845e8dcc08caf610bd1ae3f8dd2e / oracleHash: 271b418a3346d1ba53e6470992a948ad69ca94860a55d7454adb1e32124c7d73
- packetId: 39fc8279-dccf-4650-a17d-ab8fa9805d68 / packetHash: f89525d5d2665718cca09202580a35af40f9e01e0724144e035c1d5b23345d55 / questionHash: ebd61004fae23b674b3a27c9e45b95a78730c8fe758b4428459d05dceb6b5877 / planHash: 2a8e62223ae110cfc0c75c2fbaf4beaac347bb2f478c17813d7a8851f44b704f / oracleHash: 6095c976f21a98c9f9ea2f49028b5823e9c262e4a54ea3803b740a0ea3166ba5
- packetId: 4d5eef54-b0d1-4cf1-ade0-ab3819c92201 / packetHash: f9b8e75e0df466ad11933fff690f0d7f1b5bdb9d9caae1a3971f175e04c2a820 / questionHash: 5a923a1030ae4e8307db54094cc13fd2790e9fda796614f711007910b9c9d607 / planHash: d23260d8e0afbbb695227e72c4e515aae28e5219ae0e6db602d45c2856e2d014 / oracleHash: 63d207c3d1bf93087cf042e0fe370f5ed6a4df3c9cbe0edb62d360fa40621d5d
- packetId: 5ce1cf93-8625-4b99-acd7-8c5621bd5aaf / packetHash: f8bdc5c1816300ba415c6493c503e9a297cc79f43f6abca651217aa09da895e1 / questionHash: 5a923a1030ae4e8307db54094cc13fd2790e9fda796614f711007910b9c9d607 / planHash: 8de6e321b31b0eff2fdd2f2e3555a9ff9bfa560e757ce45cd59af8289622f238 / oracleHash: 63d207c3d1bf93087cf042e0fe370f5ed6a4df3c9cbe0edb62d360fa40621d5d
- packetId: 64b70a03-2e8c-460e-83c9-9df52df1db4a / packetHash: fd193c26344876c9f9a9d4841e8d9c721ad79bd906077d27fe614843aacdf618 / questionHash: 4c017cf301a210ce35a47e30c2ba50bdf2917c03434de526c89a462ddfb6f25b / planHash: 22fa9b2ea2758b0b1818134b6bd719ea93faa95b5ccb8f3ff09517ca6a6bfe19 / oracleHash: cf7901827e22ea7799446e94bc148ab1b06f662bd69d8bfe38f80a6747a994ca
- packetId: 9ebe5326-1d52-4f4d-a2d3-dae0fffd37c9 / packetHash: 8d66e47f17fda5fd71d120bc6c2dd357c7b3e0573d8616828f95d712c585c6e4 / questionHash: 4c017cf301a210ce35a47e30c2ba50bdf2917c03434de526c89a462ddfb6f25b / planHash: 22fa9b2ea2758b0b1818134b6bd719ea93faa95b5ccb8f3ff09517ca6a6bfe19 / oracleHash: cf7901827e22ea7799446e94bc148ab1b06f662bd69d8bfe38f80a6747a994ca
- packetId: c8f04bf3-cc95-4994-b0d0-18521b0dbf1c / packetHash: 978dcba8f8b74688ad0079f01c79cc74f7bba2a27d4c66543401d3c64bf46241 / questionHash: 9095ac8eebccb2eca75ffd189ccad24be49dbbfd62e8beb35a441751a3c1d5b0 / planHash: 65afec9a9b10a57ae4c1a78b0f6a6d5d9ce8806c5984961707f457e72957437b / oracleHash: 271b418a3346d1ba53e6470992a948ad69ca94860a55d7454adb1e32124c7d73

原質問・plan全文・quote・offsetを共有へ転記していない。本書は保存後変更しない。登録・armへの対応は親の凍結mappingとgateで別途確認する。Projectの資料の更新: なし。
