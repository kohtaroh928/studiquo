# 対象role比較：stage1 独立意味監査

2026-10-16。中立packet6件に含まれる実質問・実plan・provenance・oracleをそれぞれ確認した。private job mapping、variant、指示本文、期待改善結果は参照せず、mock採点をimportしていない。追加API・キー読取・既存source変更・登録なし。

各packetの判断は次のとおり。

| packetId | 確認した要求構造 | 承認対応 |
| --- | --- | --- |
| 42d5cca2-9de3-4417-952c-c5c864b734bc | 前文対象と後文手順説明の1要求 | t1→r1 |
| 64fa8d00-2a43-40de-9f71-5cfa5e8effa7 | 別対象・別属性の独立値2要求 | t1→r1、t2→r2 |
| 85142a37-8379-4121-aa9b-3484eb07d353 | 別対象・別属性の独立値2要求 | t1→r1、t2→r2 |
| e6a8a1e0-a65b-4dad-9db6-574e8c8af66b | 前文対象と後文適用状況付き条件1要求 | t1→r1 |
| ee714f4a-cd8f-439f-a358-def132a80611 | 前文対象と後文適用状況付き条件1要求 | t1→r1 |
| f7a86e79-5d45-4a93-8d8d-8704a4de2a9e | 前文対象と後文手順説明の1要求 | t1→r1 |

手順説明の2packet：先行文の明示対象をsubjects/u1、後続文の手順属性と説明依頼をattribute/requestUnitIdsのu2へ対応させている。宣言文を別taskへ増やさず、求められていない適用条件や別操作を追加していない。

独立値2要求の2packet：各対象と属性の組合せを保ち、両taskへ両対象を混入させていない。subjectはoracle代表注釈の先行文の出現箇所ではなく、実際に各要求を述べた後続文の同じ対象の出現を参照している。この参照は原質問中の明示的に同一の対象を指し、各属性との関係を直接含むため妥当な代替箇所である。代表位置不一致をfailにはしない。

状況付き条件要求の2packet：先行文の対象をsubjects/u1へ、後続文の申請状況をconditions/u2へ分離し、適用条件の説明要求を1taskとして保持。条件そのものの対象を適用状況へ移す誤りや、適用状況を追加対象へ扱う誤りは見られない。

全packetで対角pairの operation / attribute / subjects / conditions / intent / scope / provenance / noInventedDetails の8観点をpassと判断した。2taskを持つ2packetでは全2×2候補を個別確認し、交差pairは属性・対象・意図・scopeが異なるためfail、操作・空のconditions・原文unitの存在・質問外情報を捏造していないことはpassとした。1taskの4packetは各1×1を確認した。計12pair候補中、承認8・交差除外4。全要求は現契約でrepresentable。対象不明を補完したり値や解答を生成したりせず、3つの支持/許可指定をunknownに保っている。

helperは6件ともreviewed_match / reviewComplete=true、各matchingは要求数と一致し、missing/extra上下限0と集計した。意味判定は本監査者が先に行い、helperは提出判定の整合確認に使用した。判定内容が同じpacketもID/hash別の提出を維持する。

対象は3つの合成開発問の両出力であり、人間gold確認はpending。複数unit間の対象・属性・条件の参照を含むが、一般的な長文/未知質問/履歴/全operationの精度を示さない。要求抽出だけの評価であり、検索・回答生成・OCR・100ページPDF・iPad・本番採用の総合RAG評価ではない。版名を参照していないが既存文脈や同一OS環境を排除する厳密blind認証ではない。hash/roleも本人性・独立性の暗号学的証明ではない。

- packet export SHA256: 2bb3b67b69490d05e733a4ba92cea1ad4da68426e4a642d05840b9c197071c7e
- stage: 1
- completedRequests: 8
- checkpointHash: f9070abf6c9c569be85dc93f6bacd88df0ff51a66188dc3add937e0c9a442f82
- manifestHash: 3be1b351bb6f7c9787415ea568e3710b0bc2dde17396cdec6285b8a81a100744
- runId: b0fc8f2f-cda7-4aa7-afd4-ca8d2bab73fd
- packetId: 42d5cca2-9de3-4417-952c-c5c864b734bc / packetHash: 8246018194ba29ec3e18bf221e4f136f298c59a88c109a86457a6c937abd5db4 / questionHash: fe9fa817f2799de56bed81956db29f484005379edf87841400fc4996643b7175 / planHash: a462335e42d3348d1e5b510372eb6858c189b701ad067ab92a205e0474a5bea3 / oracleHash: e63346590ce4bc0c8e34966a70a9ddcd3afa30810106b7f8cff0149a6c5bfd57
- packetId: 64fa8d00-2a43-40de-9f71-5cfa5e8effa7 / packetHash: 73969015a92f89245750f279061885a51bda5df9dccc9f623c224f5af4eb15df / questionHash: 6d659f73008ec70ae32dfce64986918278fbae678ad1b5baa8efda1a76d04663 / planHash: 0d156bd9b863d18144d2a8dd0d1bdd54f7eeeb310191815a047a574d4a350f35 / oracleHash: 4a717ca4266c8b164fcaab6c8c2b05f5ae142b0221af46a63a7c437872edeb8e
- packetId: 85142a37-8379-4121-aa9b-3484eb07d353 / packetHash: 2e0f4b622189f643bb6b9d2bedc9d1a0f5509285706f6bf1f141b418b00ce4c2 / questionHash: 6d659f73008ec70ae32dfce64986918278fbae678ad1b5baa8efda1a76d04663 / planHash: 0d156bd9b863d18144d2a8dd0d1bdd54f7eeeb310191815a047a574d4a350f35 / oracleHash: 4a717ca4266c8b164fcaab6c8c2b05f5ae142b0221af46a63a7c437872edeb8e
- packetId: e6a8a1e0-a65b-4dad-9db6-574e8c8af66b / packetHash: b4a9abadd822edb4d2bf1c823076b10238e553aa20048d5c2032880a3d88a3ff / questionHash: 8d819d9112856a59c1832f280cf8caffae22ef4031955aee38102a0fc0806162 / planHash: 22c695bbd424c7a7bb99b40d402ac29f23f23d00ab527016fba81171fe10fb26 / oracleHash: 33d91ee466f63d356371ef27c539d5768e7bbe5f5b036db4944c1014cabbd807
- packetId: ee714f4a-cd8f-439f-a358-def132a80611 / packetHash: 16ffa4516ad701ef996a24a519dfc91a263decd347555f9f96fbee7577ad6474 / questionHash: 8d819d9112856a59c1832f280cf8caffae22ef4031955aee38102a0fc0806162 / planHash: 22c695bbd424c7a7bb99b40d402ac29f23f23d00ab527016fba81171fe10fb26 / oracleHash: 33d91ee466f63d356371ef27c539d5768e7bbe5f5b036db4944c1014cabbd807
- packetId: f7a86e79-5d45-4a93-8d8d-8704a4de2a9e / packetHash: 27b04ad4990e7d557ee056d7fb9a5af1aa5ef9ff90df52f5c33314eda89e8eae / questionHash: fe9fa817f2799de56bed81956db29f484005379edf87841400fc4996643b7175 / planHash: a462335e42d3348d1e5b510372eb6858c189b701ad067ab92a205e0474a5bea3 / oracleHash: e63346590ce4bc0c8e34966a70a9ddcd3afa30810106b7f8cff0149a6c5bfd57

原質問・plan全文・quote・offsetを本共有文書へ転記していない。保存後の本監査文書は変更しない。登録・armへの再対応は親の凍結mappingとgateで別途確認する。Projectの資料の更新: なし。
