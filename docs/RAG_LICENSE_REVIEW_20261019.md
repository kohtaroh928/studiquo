# Step 3：Linux依存・Doclingモデルの利用条件調査

2026-10-19。調査は完了、配布対応は未完。現在imageを「再配布条件をすべて満たした配備候補」とは扱わない。[証拠一覧](RAG_LICENSE_INVENTORY_20261019.json)のdistributionReadyはfalse。

## 実物で確認した範囲

既存の専用Linux VMと保存済みimage `sha256:32018601399c0791a787fd72516acfd8fddce9fe568da12d6344a4c19792bc4d`を使用。image取得/再build/配備なし。通信none・host mountなし・read-only・非root・capabilitiesなしで、Pythonを入口にOSの管理情報だけ読んだ。PDF・実資料・キーは使用していない。

- Debian 12 bookwormのインストール済み429パッケージ名/版/source、429のcopyrightファイルhashを取得。copyrightファイルの欠落0。Licenseラベルの存在だけで全許諾条件の適合とはしない。
- /usr/localのCPython licenseファイルの存在/hashを確認。baseの単一ライセンスで全OS構成物を説明しない。
- Linux用102wheelの全体hashを先行inventoryと照合し、内包する268のlicense/notice/copyright文書のpath/hashを記録した。ネイティブ依存を含む。上位METADATAのUNKNOWN8件は同梱文書/classifierとtokenizers公式同版LICENSEで名称を補足、元のinventoryやmetadata値は書き換えない。
- 同梱モデル3repositoryを特定し、全66artifactのhashを再照合した。cache metadataにあるREADMEのrevisionに固定した公式model cardとライセンス宣言を照合。hash一致は配布元の署名検証ではない。README revisionと全weightsの取得revision同一性を追加で認証したものではない。

## 主要なライセンス

| 対象 | 表記・証拠 | 扱い |
| --- | --- | --- |
| Docling2.139.0 | MIT、[同版LICENSE](https://raw.githubusercontent.com/docling-project/docling/v2.139.0/LICENSE) | 著作権/許諾表示を保持 |
| docling-layout-heron | Apache-2.0、[固定revision](https://huggingface.co/docling-project/docling-layout-heron/blob/8f39ad3c0b4c58e9c2d2c84a38465abf757272d8/README.md) | Apacheのライセンス文と該当notice等を配布形態に合わせて保持 |
| docling-layout-heron-onnx | Apache-2.0、[固定revision](https://huggingface.co/docling-project/docling-layout-heron-onnx/blob/40bde044036bb181c130ddf6c51792187268748f/README.md) | 元モデルとONNX変換版の宣言を区別して記録 |
| TableFormer accurate/fast | ローカルREADMEと[固定revision](https://huggingface.co/docling-project/docling-models/blob/fc0f2d45e2218ea24bce5045f58a389aed16dc23/README.md)のCDLA-Permissive-2.0 | weightsを共有する場合にagreement本文を伴わせる。コードのライセンスとは区別 |
| Python3.12.15 | PSFと同梱構成物別条件、[同系列公式資料](https://docs.python.org/3.12/license.html) | runtimeの同梱licenseを維持 |
| Shapely内のGEOS | wheel内LICENSE_GEOSにLGPLv2.1と共有libraryの記載。[GEOS公式](https://libgeos.org/)もLGPLと明記 | ShapelyのBSDだけではGEOSの配布条件を満たしたと判断しない |
| certifi/tqdm | METADATAにMPL-2.0等、tqdmはMIT併記 | MPL対象fileの配布/変更とソース提供条件を区別して確認 |
| PDFium/NumPy/SciPy/Torch等 | それぞれ18/20/5/90のlicense文書をwheelで確認 | トップレベルのBSD/MIT/Apache表記だけで同梱native codeを一括許可しない |

model cardの許諾に非商用限定の表記は見つからなかった。ただしこれは全依存の再配布適合やモデル品質・学習データ権利の保証ではない。

## 明らかになった配備前の残件

1. **ライセンス本文の同梱**：モデルdirにはREADMEの名称表記だけでLICENSE/NOTICEの独立ファイルがない。Docling/tokenizers等もwheel内のlicense本文fileがない。検出上はDocling/et-xmlfile/latex2mathml/openpyxl/tokenizersの5wheel（METADATAのinline文の有無とは別）。exact版の上流license/著作権表示とモデルApache/CDLA本文を配布物へ追加し、再buildしたimage内で確認する必要がある。
2. **native/OSの配布条件の履行**：GEOS LGPL2.1やOSのGPL/LGPL等について、実際の配布形態に対応するソース入手手順/対応版・notice・差し替え/再リンク条件等の適用と履行を整理する。licenseファイルが存在するだけで完了とはしない。パーサーをサーバー内で動かすことと、imageを事業者へ提供すること、iPadへ組み込むことは区別する。今回iPadへ組み込む変更なし。
3. **native第三者情報の完了確認**：268文書は抽出した証拠で、全条文の個別適合判定ではない。上流から必要な著作権/notice、モデル配布元の同版LICENSE確認をまとめて、配布前のレビュー記録を残す。
4. **OS脆弱性は別確認**：過去pip-auditの102件0脆弱性はOSパッケージや全native libraryを対象としていない。今回はOSのCVE照合を実施していない。429 OSパッケージのinventoryをその入力に使う。

[Apache 2.0](https://www.apache.org/licenses/LICENSE-2.0)の再配布条件、[CDLA-Permissive2.0](https://cdla.dev/permissive-2-0/)の共有/結果条件、[Mozilla MPL FAQ](https://www.mozilla.org/en-US/MPL/2.0/FAQ/)、[GEOS同梱条文](https://raw.githubusercontent.com/libgeos/geos/main/COPYING)、[Debian copyright配置規約](https://www.debian.org/doc/debian-policy/ch-docs.html#copyright-information)を参照した。これは実物と許諾情報の技術調査記録であり、全配布条件の法的適合判断を完了した記録ではない。

## 検証・次工程

一覧の429/102/268/66の件数とhash、Step1の固定374ソースhashの一致、git diff --checkを確認。機能コードやDockerfile/依存/model本体は変更せず、機能テストも再実行していない。調査用containerは自動削除、専用VMも停止した。新API/有料評価/remote変更なし。

次はStep4の保存期間・削除順の設計。上の配布条件対応/OSセキュリティ確認は、Step8の配備許可とStep9のimage uploadより前に閉じる必要がある残件として保持する。調査完了を配布可へ読み替えない。
