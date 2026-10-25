# Private Docling execution boundary (not deployed)

This separate Worker uses the direct Durable Object Container API. The staging MCP service binding and authenticated raw-PDF HTTP routes are now implemented, with execution and admission flags disabled. The sample configuration keeps execution disabled, workers.dev and preview URLs off, and has no public routes; fetch handlers also return 404.

The default and named `DoclingProcessor` entrypoint exposes `parse(jobId, pdfBytes)` and `cancel(jobId)` only to a trusted service binding. IDs are canonical UUIDv4 generated server-side by that caller. The ID is not authorization. Before any app connection, that caller must enforce raw-PDF consent, canonical owner/document generation, deletion/revocation and paid-work admission. Those controls are implemented in the separate MCP raw-PDF caller; they remain outside this private Worker. Cancellation remains callable while new execution is disabled.

`DoclingJob` stores only opaque ID, status, deadline and cleanup attempt count. No raw PDF, text, parser error, title, account identifier, digest or output is written to DO storage. A claimed job is single-use across eviction/restart. Completed/failed tombstones currently persist; production retention/compaction and billed storage must be decided before enablement.

The job persists its deadline alarm before starting, sets `enableInternet:false`, polls `/ready` without a document, submits PDF `/parse` once, reads a bounded response and checks the document binding/full page envelope. Final Swift and Worker structured validators are still required. Work deadline is 125 seconds total including startup; startup polling is limited to 30 seconds within that deadline. Destruction has a separate wait bound of 10 seconds. These are application timeouts, not a platform billing cap or physical erasure guarantee.

Success is returned only after container destroy resolves and the job is still valid. Explicit cancel and alarm invalidate late results. Destroy failures poison the job and retry cleanup with bounded backoff; exhausted failures remain operational incidents. Caller disconnect does not automatically propagate across RPC: the caller must issue the explicit cancel RPC and reconcile it with its authorization ledger.

The sample uses default scheduling with image and instance size fixed in configuration, matching the installed Wrangler schema. It does not use `ctx.container.images`, runtime image selection, snapshots or arbitrary exec. The newer durable_object scheduling policy is a separate migration, not mixed into this sample. `wrangler.example.jsonc` is an example, not an active deployment config. Its empty base-image argument and missing offline provisioning intentionally prevent an accidental image build.

Tests load the real JavaScript classes with a small `cloudflare:workers` shim and fake storage/container lifecycle. They cannot prove actual Cloudflare alarm delivery, input gates, network isolation, VM destroy, service-binding framing or Linux model availability. Python loopback and a synthetic Docling interoperability smoke are separate evidence. A dedicated local Linux VM has now built and run the real linux/amd64 image; real local workerd service binding and authenticated HTTP integration also passed. This does not verify deployment or isolation on actual Cloudflare. See [current report](../../docs/RAG_LINUX_PUBLIC_CONNECTION_REPORT.md).

See `../docling-container/README.md` for offline provisioning and build-context restrictions. No dependency/model download, image push, resource creation, migration application or deployment is authorized by this preparation unit.

References: [direct Container API](https://developers.cloudflare.com/containers/api/durable-object-container/), [DO concurrency/reset rules](https://developers.cloudflare.com/durable-objects/api/state/#blockconcurrencywhile), [container config](https://developers.cloudflare.com/containers/configuration/wrangler/).


## Step5-D1: opt-in v2 boundary (local only, 2026-10-20)

`DOCLING_RPC_V2_ONLY=true` selects strict `parseV2({version:2,jobId,pdfSha256,notAfter},bytes)` and `cancelV2({version:2,jobId,notAfter})` on both entrypoint and DO. Legacy signatures are rejected in this mode. Execution uses the fixed deadline, never extending it on replay/cancel. Cancellation remains available after expiry; an expired empty DO still requires destroy confirmation without creating a marker. Legacy states can be stopped without inventing a v2 deadline.

The flag is not set by this change. **Do not enable it with the current legacy MCP callers.** D2a must persist the immutable envelope before dispatch and migrate every stop/recovery/account caller. No finite purge or deleteAll is implemented, and existing markers remain. Local RPC/SQLite smoke uses a synthetic VM-destroy override, not a real Container. See `docs/RAG_DO_V2_BOUNDARY_REPORT.md` for tests, limitations and rollout prerequisites.


## Step5-D2a v2接続（2026-10-20）

MCPのRAG_PDF_RPC_V2_ENABLED opt-inからparseV2/cancelV2へ接続済み（ローカル実装）。0018でdispatchと固定envelope保存を原子化し、保存v2 jobはMCP受付flagをOFFにしてもcancelV2を維持する。旧pendingは元job.deadlineによるcancelV2でdrainし、v2 parse用digestを補完しない。配備時は新規受付を止め、0018＋cleanup対応MCPを先行準備し、private DOCLING_RPC_V2_ONLYとMCPのflagを整合させてから再開する。不整合は受付/停止失敗として保持し、downgrade fallbackしない。今回flags/remoteは未変更、有限DO purgeは未実装。

詳細: [接続検証](../../docs/RAG_PDF_RPC_V2_INTEGRATION_REPORT.md)。


## D2b-A：停止観測と削除前提（2026-10-20）

cleanupはv2のdestroy解決後に初回destroyConfirmedAtを保存し、保存/時計/alarm失敗時は成功ackを返さず保持する。これは過去の観測で、現在停止/全task静止/削除許可を証明しない。legacy/期限後空DOへは追加しない。全消去後の時計巻戻しで古い契約が再有効になるため、外部fence等を確定するまでdeleteAll/物理purgeは実装しない。retention alarmは未追加で、既存alarmはcleanup専用。
