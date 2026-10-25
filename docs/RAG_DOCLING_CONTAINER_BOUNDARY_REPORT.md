# Docling Container実行境界のローカル実装

2026-10-17。独立したprivate Worker/DO、container専用Python入口、未ビルドDocker recipeを追加した。既存MCP WorkerやiPadからの呼出しは接続していない。実Cloudflareで動作する状態まで完成したとは扱わない。

## 変更と目的

services/docling-worker/のDoclingProcessorはprivate service-binding RPC向けparse/cancelを持つ。public HTTPは404、sampleはworkers.dev/preview/public routesなし・実行flag false。既存mcp-serverの設定/依存へ今回bindingを追加していない。UUIDv4 job IDは未来の認可済みserver callerが発行する前提で、ID自体は認可ではない。

DoclingJobは同じjobを再実行しない。起動前に非本文状態と期限alarmを保存し、固定image/VM sizeをsample configに置くdefault scheduling、direct ctx.container.start({enableInternet:false})、固定8080/ready確認→parse POST一回へ接続する。PDF10MiB・応答4MiB、startup30秒はwork全体125秒の内側、破棄確認は追加最大10秒。本文・原PDF・digest・内部error・account情報をDO storageへ保存しない。

成功結果はdestroy解決と状態再確認後だけ返す。明示cancel/alarm/monitor失敗で遅延結果を捨てる。破棄失敗はpoisonとcleanup回数を保持し、最大3回のalarm再試行（10/30/90秒）を予定する。原PDF処理そのものはretryしない。呼出元切断のRPC自動伝播は仮定せず、future callerのcancel RPCと認可台帳の照合が必要。

services/docling-processor/container_entry.pyは明示Container専用入口だけ0.0.0.0:8080を許可し、従来local adapterは127.0.0.1を維持。readyは本文なし204、busy/poisonは503。固定配置、Docling2.139.0/regex2026.9.29と既存model inventory hashをready前に確認する。startup orphan cleanupは専用root/prefix/所有者/mode/inodeを検査し、symlink・hardlink・不明entryを拒否、FD-relative no-follow・深さ16・総entry1万・総bytes256MiBに制限。SIGTERM/INTで既存runnerの終了・清掃を待つ。

services/docling-container/のrecipeは非root UID10001、root-owned readonly code/runtime/models、private jobroot。専用Dockerignoreで固定sourceと明示provisioning入力以外を除外する。Linux baseはreview済digestの明示必須、offline wheels/全transitive hash lockとmodels未提供ではbuildが止まる。pipはno-index/require-hashes/only-binary、RUN network none。macOS lockをLinux用にコピーしていない。実行時のinstall/model downloadもない。

## 検証結果

- JS実class + cloudflare:workers shim + storage/container fixture: 28件成功、失敗/skip0。親と独立reviewがそれぞれ同28件を実行。
- Python関連60件成功（container14、HTTP27、既存runner17/child2）。loopback実socketを含む。既存tools/docling49件も成功。今回mcp-server/iOS変更なしのため全Worker/iOSは再実行していない。
- Wrangler4.130.0でsample configからEnv/Runtime型生成が成功。生成先はprivate tmp。生成型のContainerStartupOptions/getTcpPort/destroyと実装を照合、esbuild bundleと構文確認、git diff --checkも成功。これはdeploy dry-runや実Container動作の確認ではない。最初の通常sandbox型生成はログ書込とloopbackの制限で失敗し、tmpログ指定・許可されたlocal実行で成功した。
- 実JSのDoclingJob（DO/runtimeはshim）→Node fetchによる実loopback HTTP→ContainerHTTPProcessor→実offline Docling→prepared manifest検証を合成2pageで確認。parse POST1回、ready2回、修正後6.11秒、helper停止後に返却、job directory削除。最初の同interopは6.488秒。本文は表示/保存していない。Container lifecycleだけはhost helperによるmockであり、Cloudflare VM起動/destroy・OS通信隔離・Linux互換を証明しない。
- Docker/Podman実行環境が無い。Linux base/wheels/hash lock/provisioningを取得しておらず、image build・image push・実VM起動は未実施。通常の合成テスト/Docling以外の有料API・鍵読取・追加model downloadなし。

## 独立レビューと修正

Plannerで契約を確認し、別Code Reviewerがセキュリティ境界もレビューした。初期の13件/18件の成功を完成判断に使わず、次のHigh2件を修正した。

1. 状態保存が失敗すると停止処理へ到達しない経路。execute/cancel/alarm/monitor/constructor回復の保存処理と破棄を分離し、storage get/put/setAlarm/deleteAlarm障害でもdestroyを最善努力で必ず試す。正常な重複拒否・別job取消は先行jobを止めない。
2. blockConcurrencyWhile callbackの例外は実DOをresetする公式仕様。単なるrejectのshimでは検出できていなかった。全gate内部で例外をoutcomeにして外側で固定errorを返し、callbackから例外がescapeしないことを全テストで検証した。

起動直前cancel/alarmでstart0、state保存障害で成功なし、本文非保存、遅延結果破棄等の回帰を追加。初期化promiseのLow未処理rejectも即時handlerで修正し、元rejectをparse/cancel/alarmへ保持する。最終独立28件成功、未解決High/Medium/Low指摘なし（未公開local単位の範囲）。

## 選択理由と限界

最新公式は新規アプリにdirect Container APIを推奨している。一方、installed schemaはdurable_object schedulingを列挙していないため、SDK/CLI更新を勝手に行わず、default policyでimage/instanceをconfig固定とした。新policyのimages runtime APIと混在させない。sampleは旧migrationsを使い、exportsと併用しない。

VM size/max_instancesは資源設定であり課金上限ではない。raw PDF専用同意、canonical owner/文書generation、admission/予算予約、取消・削除連携、iPad自動送信は未実装。実行flagを有効にする条件ではない。

storage自体の障害ではpoison/alarmを永続保存できない場合があり、メモリ上の停止とdestroy試行で失敗を返す。破棄も失敗し再試行不能になれば運用で停止確認が必要。このunitだけで物理消去・全故障時停止を保証しない。tombstoneは現在無期限に残るのでproduction retention/compaction、監視/通知も有効化前に決める。

Docker recipeの静的確認とLinux実buildは別。native共有library、依存/モデルlicense・脆弱性、cold start、memory、実FetcherのHost/Content-Length、VM reset後のdisk、egress無効化、alarmとstorage gate挙動、signal/cancel/費用は実環境で検証が必要。mockテスト成功を回答精度向上と混同しない。

## 公開・停止・次工程

remote resource作成/migration適用/配備/追加購入は行っていない。既存RAG flagsと自動スケジュールPAUSEDも維持。未接続中のrollbackはflag false・既存Worker未bindingのまま新moduleを使わないこと。後に接続する際は新規受付停止後もcancel/alarm cleanupを保持する。

次はLinuxビルド環境・hash lock・native library/model同梱の確認と、原PDFの別同意/認可/admission・取消削除の呼出元実装。これらを満たす前にiPadから送信しない。

Project資料の更新が必要: ARCHITECTURE.md、DATA_AND_MIGRATIONS.md、SECURITY_AND_PRIVACY.md、HYBRID_RAG.md。Desktopの複製は未変更。

公式根拠: https://developers.cloudflare.com/containers/api/durable-object-container/ 、https://developers.cloudflare.com/containers/configuration/wrangler/ 、https://developers.cloudflare.com/durable-objects/api/state/#blockconcurrencywhile 、https://docs.docker.com/build/concepts/context/#dockerignore-files 、https://pip.pypa.io/en/stable/topics/secure-installs/ 。
