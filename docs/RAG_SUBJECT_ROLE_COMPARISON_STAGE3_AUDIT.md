# 対象role比較：stage3 独立意味監査

2026-10-16。中立packet8件の実質問・実plan・構造参照・oracleを個別に監査した。private mapping・variant・指示・期待改善結果は参照せず、mock判定をimportしていない。追加API・キー読取・登録・既存source変更なし。

| packetId | 監査根拠 | 観測したstatus | 対応 |
| --- | --- | --- | --- |
| 29352c9c-0f77-4bef-8f77-285bc0acdae1 | 対象未指定の属性値要求を保持しsubjectsを捏造しない | candidate | t1→r1 |
| 58ae36e4-8803-4771-a3c0-8820ad6e55ff | 対象名なしの宣言と後文の属性値要求を保持。status差は別途未評価 | needs_clarification | t1→r1 |
| 75ece6d1-6897-42d0-ae83-9663932b1059 | 対象名内の操作語を別操作へ変えず、所在地の値要求を保持 | candidate | t1→r1 |
| 7bbe6540-cbbf-4e81-92d4-66341a2c135c | 対象未指定の属性値要求とsubjects空を保持。status差は別途未評価 | needs_clarification | t1→r1 |
| 87bdd917-7ce6-48cb-8de2-12fd4bc7f094 | 対象名内の操作語を別操作へ変えず、所在地の値要求を保持 | candidate | t1→r1 |
| bbe6b1e0-4ba8-4563-b19d-abb437aa71b5 | 明示対象だけを保持し背景の例を追加対象へ混入しない | candidate | t1→r1 |
| dff5e289-fcb7-4c22-8a6e-ce41a199fddd | 明示対象だけを保持し背景の例を追加対象へ混入しない | candidate | t1→r1 |
| f8b99828-ace3-44a0-af9e-819fa5edb942 | 対象名なしの宣言と後文の属性値要求を保持しsubjectsを捏造しない | candidate | t1→r1 |

各packetの全task×requirementは1×1、計8pair。operation / attribute / subjects / conditions / intent / scope / provenance / noInventedDetails の8観点を要求taskの対応についてpassと判断し、各要求を現契約でrepresentableとした。

対象不在の4packet：属性の値を知りたい意図を保持し、質問にない対象名・適用条件・値・回答を補わない。subjects空は欠落ではなく原質問に明示対象がないことと整合する。2文のケースでは属性と依頼は後文unitを参照する。単文ケースは唯一のunitを参照する。

重要な差として、対象未指定の各問で片方はcandidate、もう片方はneeds_clarificationとreference未解決を出した。後者も同じ要求taskを保ち、追加の架空対象は作っていない。凍結oracleは属性要求の保持・対象非捏造を評価し、回答可能性や追加質問の要否を確定しないため、このstatus差だけをtask対応のfailへ変更しない。一方、この差を隠して両出力の全挙動が同じ、clarification判定が正しい、実際に追加質問なしで回答できると主張しない。status/unresolvedの実運用上の妥当性・過剰確認/確認不足はこのoracleでは未評価である。

対象名に操作語を含む2packet：先行文の明示対象をsubjects/u1、後続文の属性値と依頼をu2へ結び付ける。対象名の一部を比較操作として追加せず、一つの値要求を保持する。

背景の例を含む2packet：先行文の例示名詞を対象に混入せず、質問対象を宣言するu2からsubjectsを、依頼のあるu3からattribute/requestを参照する。説明要求を1taskとして維持し、背景の説明や比較を勝手に追加していない。

原文unitの存在だけで意味対応を承認せず、ラベル・役割・依頼scopeを個別に確認した。全packetでunknown支持/解決/比較許可を維持する。helperでは提出した8pairが全件reviewed_match / reviewComplete=true、承認・可能matchingは各1、missing/extra上下限0と集計された。これは提出reviewの整合確認であり自動意味採点ではない。

対象は4合成開発問の要求抽出だけ。人間goldはpendingで、小標本・既知開発問の結果から汎用精度や候補の優位性を断定しない。検索・回答生成・OCR・100ページPDF・iPad・総合RAG・本番採用の合格は未判定。中立packet監査だが既存開発文脈や同一OS環境を排除した厳密blind認証ではなく、hash/roleも本人性・独立性の暗号学的証明ではない。

- packet export SHA256: 32040c7ff411c7be4bf31ec072507b146a3cae744ab8297091b9888cdae0f905
- stage: 3
- completedRequests: 24
- checkpointHash: 5b8b4820c82afee4cad4fd4d2f3c965396190d2e68eb7c962c313e4d3c8e1d6d
- manifestHash: 3be1b351bb6f7c9787415ea568e3710b0bc2dde17396cdec6285b8a81a100744
- runId: b0fc8f2f-cda7-4aa7-afd4-ca8d2bab73fd
- packetId: 29352c9c-0f77-4bef-8f77-285bc0acdae1 / packetHash: 10f7a8a7d70a9009728cb854faf973ab05629cea38cea387f99802484b852730 / questionHash: a32dec33d1a20e5f8620cafd5b051e6e0af840145c001bfef9cd1dad1ad38ce5 / planHash: 9d50f7a9b66c1807751a7524039e115b0b08d3455e791f2c5eb67a2c542ebf5a / oracleHash: 138d4eb83840df8fe35a4421ecd0a7af99391a07bb401bb74fa256a95bef5ce5
- packetId: 58ae36e4-8803-4771-a3c0-8820ad6e55ff / packetHash: 060a441cb639d48469bfdb878416e2d4eb8467341030557c2d75e61317636e9d / questionHash: deb3f58abfcb571deec59a7492254c45902faeec6e852c1f567823d54e5ee193 / planHash: 4686919de131e469a0802ffbc25d4c05af28708b8ec4a7fe778da776909f0098 / oracleHash: 366fb3d6f8fe9866791cf875386dbe0608b3d06bb2e1bcceee901e8ddf0f3770
- packetId: 75ece6d1-6897-42d0-ae83-9663932b1059 / packetHash: 013935809b933055a8ad5308e202ad4d694960205b5707bfcfd1e9a4f3356dd7 / questionHash: 2ac6d4fe53a1c217cf4a5f023b62f109ab309185ab479ef0bbcf611f32adc138 / planHash: ef27bb7ac8c3a217fddcf7aaf0bae68822443ca2d9d2774d655de4200b63a633 / oracleHash: 86b08db235fd14bee73d82b7cd8b4b30eada56a01da9a3ea095bf00adb3271ab
- packetId: 7bbe6540-cbbf-4e81-92d4-66341a2c135c / packetHash: 1c62162bab63192242bfb6a1d300decfa11f25d414797258f32b01486694f8c9 / questionHash: a32dec33d1a20e5f8620cafd5b051e6e0af840145c001bfef9cd1dad1ad38ce5 / planHash: 0bb7dd055de1d58d3f4e7940c3d45d20a92c5b7ccf0b8b02362f23da478b455c / oracleHash: 138d4eb83840df8fe35a4421ecd0a7af99391a07bb401bb74fa256a95bef5ce5
- packetId: 87bdd917-7ce6-48cb-8de2-12fd4bc7f094 / packetHash: 5370ff91b9f0d3869bf84242f4aa96bae40e84b8aa766ac701265b455cd370b1 / questionHash: 2ac6d4fe53a1c217cf4a5f023b62f109ab309185ab479ef0bbcf611f32adc138 / planHash: ef27bb7ac8c3a217fddcf7aaf0bae68822443ca2d9d2774d655de4200b63a633 / oracleHash: 86b08db235fd14bee73d82b7cd8b4b30eada56a01da9a3ea095bf00adb3271ab
- packetId: bbe6b1e0-4ba8-4563-b19d-abb437aa71b5 / packetHash: 5a5f34ec690fdd4a0d56724231479dc8a8f5505fc308c261f9b1019bdeec41aa / questionHash: 08eaf9e9bd3c90172f10d04fc4585f182c79feb0201b343d8e09d73935764719 / planHash: 3c14fedc3f996375ad0c9bc3f3b41fdd0ba3b077fce13992455ee1987efef79f / oracleHash: 24c6276fbe4e4fab7d70f8ba9a9b5ae3d2f73920cb210611080c7fb88f0ccd9a
- packetId: dff5e289-fcb7-4c22-8a6e-ce41a199fddd / packetHash: 1b4ebe44213aa0a38ed7eede333082e271fcc798fe24bdaf77c988ff78a4477f / questionHash: 08eaf9e9bd3c90172f10d04fc4585f182c79feb0201b343d8e09d73935764719 / planHash: 3c14fedc3f996375ad0c9bc3f3b41fdd0ba3b077fce13992455ee1987efef79f / oracleHash: 24c6276fbe4e4fab7d70f8ba9a9b5ae3d2f73920cb210611080c7fb88f0ccd9a
- packetId: f8b99828-ace3-44a0-af9e-819fa5edb942 / packetHash: 3e1be3dd8065fd598fa03cfbe9fd2f41082b2fef927754e277a361c92a27f9f3 / questionHash: deb3f58abfcb571deec59a7492254c45902faeec6e852c1f567823d54e5ee193 / planHash: 7db76451102e616300205c33020b0f0341b575ae6ba5221d8663c59082c6ef1f / oracleHash: 366fb3d6f8fe9866791cf875386dbe0608b3d06bb2e1bcceee901e8ddf0f3770

原質問・plan全文・quote・offsetを共有へ転記していない。本書は保存後変更しない。提出の登録・arm対応・比較判定は親の凍結mappingとgateで別途実施する。Projectの資料の更新: なし。
