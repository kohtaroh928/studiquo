# 実Linuxと原PDF公開HTTP接続の検証

2026-10-18。LinuxとローカルWorkersでの接続完了。**Cloudflare上への配備・公開URLの有効化は未実施**。iPadの新Notebook正式採用・索引移行は別工程。

## 実装

- app.jsのrealSession認証の後に原PDF専用handlerを接続。GET/POST `/api/rag/pdf/consent`、POST `/api/rag/pdf/intakes`、POST `/api/rag/pdf/intakes/:UUID/process`、POST同`:UUID/cancel`。
- 本人は認証sessionから計算し、opaque intake UUIDからownerを限定して保存済みproofを復元する。digestをURLへ入れない。raw本文をJSON privacy readerへ通さない。
- flags、private binding、server側の厳密policy、migration、rate、両同意・最新intakeを本文取得前に確認。受信前のreserve/claimと10MiB上限を維持。取消/撤回はflags offでも使用可能。
- NDJSON v1はbegin→番号付きmanifest断片→complete。最大4MiB/転送全体30秒、backpressure/読取要求時の再認可。manifestは暫定で、completeと全長/manifestSHA256/原PDFdigestが一致するまで採用しない。
- 受付枠を保持したまま全manifestを転送し、参照解放・実停止精算・最終再認可後だけcompleteを出す。取消/切断/精算失敗はcompleteなし。新しい本文保存先は追加しない。
- worker.jsのcleanupは別RAG_PDF_CLEANUP_ENABLEDで制御し、受付flagsを閉じても停止可能。設定はfalseを維持。stagingにだけprivate service bindingと明示policyを用意し、本番にはprivate bindingを追加しない。

## 実Linux

Apple Silicon上の専用Colima VM、ホーム共有なし。公開公式のARM版Colima/Limaはハッシュ確認、Docker CLIは公式配布を使用。amd64コンテナをRosetta経由で実行し、Linux `x86_64` を確認。Cloudflareが要求するlinux/amd64を対象にしたが、実Cloudflare VMの証明とは分ける。

baseはPython3.12.15の公式bookworm、`python@sha256:5560e9ab8709f459489e5b8aa696eda8a07ef821e14bb122be62d91234bfa98b`。Linux専用に102wheelを解決し全hash lockを生成。Docling2.139.0/regex2026.9.29/torch2.14.1+cpu/torchvision0.29.1+cpu。macOS freezeをLinux lockとして流用していない。CPU wheelだけupstream PyTorch index、残りはPyPI、PIP_*とpip.conf/PYTHONPATHの影響を除去する準備toolを追加した。

モデルは既存offline inventoryを再検証。image buildのpip installはnetwork=none/binaryonly/require-hashes。build contextは既存allowlist、原PDF/キー/ユーザー資料なし。依存/モデルはignored provisioned領域で、Gitへバイナリを入れない。

実コンテナimage ID: `sha256:32018601399c0791a787fd72516acfd8fddce9fe568da12d6344a4c19792bc4d`。

合成の本文/表2ページ、22.908秒、8454bytesのmanifest、parse POST1回。UID10001、ネットワークnone、host mount/公開portなし、read-only rootfs/capabilitiesなし。外向き接続拒否、code/model書込み拒否、一時job領域回収、不正PDF拒否、実子process取消、短縮テスト期限0.3秒でのkill/reap、SIGTERM正常終了を確認。サーバー本来の120秒設定は変更しない。cgroup memory.peakは1,272,651,776bytesで、MCP側64MiB受付weightとは別のVM内消費。すべてのPDFや100ページ資料での性能保証ではない。

pip-auditで102依存を照合し、既知脆弱性0・skip0（CPU版はupstream基底版で照合）。これはPython依存の照合時点の結果で、Debian全体・将来CVE・ライセンス法務承認を保証しない。wheel license inventoryを作成済み。

## 実Workersとの通し

専用local D1に0001〜0013を適用し、本番/既存preview KVを使用しない。実wrangler/workerd、realSession、公開app入口、private service binding、DoclingJob、実amd64 Linux解析、NDJSON complete、job settled/ever_dispatched1/settled_units1まで成功。合成2ページは約21.045秒。Docling container/volumeは終了後に残存なしを確認。生token/本文/manifestをログや報告に保存していない。

使用Wrangler4.130.0のworkerd上限に合わせ、専用local/staging設定のcompatibility_dateは2026-09-15。元のサンプルの2026-10-17や新規2026-10-18では起動できず、実試験用設定だけを修正した。本番の既存dateは変更しない。ローカルContainers SDKはproxy helperでSYS_ADMIN/FUSE等を使う旨の警告があり、厳密なread-only/network-none単体試験と同じ隔離条件ではない。Cloudflare実環境のegress/alarm/destroyはまだ確認していない。

## 実試験で修正した問題

1. 未配備0010の`epoch=CASE`をWranglerがcompound CASEとして認識せずSQLを途中分割。`epoch= CASE`へ修正し、実splitter回帰とlocal D1適用を確認。
2. `python -I`はscript directoryも除外するためcontainer起動でprivate_http importに失敗。root管理の固定__file__親だけ復元し、cwd/PYTHONPATHを使わない回帰を追加。
3. HTTP Responseを早く返すとworkerdが未受信のrequest bodyをcancel。reserve/claim後に有限readerで完読した通知までResponseを待つよう修正。Nodeだけのテストでは検出できなかった。
4. wheelにvendored dist-infoや特殊license欄が含まれるケースへ対応。pip追加供給元の継承とDocker起動応答不明時のcleanup漏れは独立レビューで修正。

最初の一行だけの手製PDFはDoclingがページ横断要素へまとめたため、既存strict validatorが要確認として拒否した。成功扱いへ基準を緩めず、本文/表を含む既存合成fixtureで本線を確認。図/OCR/不明な構造の公開対応を拡張したものではない。

## 検証結果

サーバー全体1851件成功（fail/skip0）、公開HTTP/app/process関連42件成功、Python processor61件、Linux provisioning6件成功。件数は重複を含むため合算しない。独立Code/Security reviewの指摘を修正済み、独立再テストなし。MCP/private stagingのdeploy dry-run成功、配備・image uploadなし。テスト成功は回答精度改善の証明ではない。

## 配備前の残件と停止方法

配備対象案は既存studiquo-mcp-stagingと新studiquo-private-docling-staging（max_instances1）のみ。0009〜0013等の適用済み状態・backup・既存staging versionを実配備前に確認する。private→staging bindingの順で配備、合成PDFの限定試験だけで確認する。本番の有効化、iPad公開、購入/課金プラン変更は別判断。

containersは従量費用が発生するため、実配備と利用範囲/予算を承認後に進める。max_instances1やshadow unitsは金額のhard capではない。受付停止はRAG_PDF_PROCESSING_ENABLED=false、private new parse停止はDOCLING_EXECUTION_ENABLED=false。cancel/alarm/cleanup bindingと台帳を残す。rollbackでmigration/世代/失効記録をdropしない。

今後の残件: 実Cloudflareの隔離/停止/alarm確認、claimed停止証拠付き自動回収、retention、iPadの厳密なstream検証と新Notebook正式採用/registry移行。受信中断時は同じintakeを再解析せず、結果再取得保証もない。
