# Offline Docling processor boundary

`PDFProcessor(python_executable=..., artifacts_directory=...).run_pdf(pdf_bytes, cancel_event=threading.Event())`
accepts only in-memory bytes of one PDF and returns `PreparedResult(manifest, pdf_sha256, total_pages)`.
Paths are trusted startup configuration. Request fields cannot select commands, URLs, modules, artifacts or filenames.

- Input: PDF magic, nonempty, at most 10 MiB. At most 20 complete pages.
- Work deadline: 120 seconds checked around setup, child conversion, packaging and reading; process reaping may take up to 2 additional seconds. This is not an end-to-end HTTP wall-time guarantee. Cancellation and deadline kill the child process group with SIGKILL; no automatic retry.
- Output: existing `prepared_only_no_upload` manifest, at most 4 MiB; body chunks and protected elements follow the existing validators and are never resplit here.
- Private job directory mode 0700, input/intermediates/output mode 0600. Every normal exit attempts job-directory removal, and success is returned only after removal; cleanup failure is reported explicitly. Stdout/stderr go to the null device. No user body, filename or parser error is logged.
- Child calls the pinned existing `tools/docling/extract_pdf.py` pipeline then `index_payload.prepare_batches`. Existing checked model artifacts only; offline environment, remote services and external plugins disabled. No encoder download or semantic vectors are introduced.
- CPU hard limit 120 seconds, intermediate file hard limit 16 MiB each, core dumps disabled. Native parser memory is **not** OS isolated here. Python network blocking is defense in depth, not a native network sandbox. The future service must add container/network isolation and concurrency/resource admission before public exposure.
- Fixed errors: `configuration_invalid`, `input_invalid`, `cancelled`, `timeout`, `conversion_failed`, `output_invalid`, `cleanup_failed`. They contain no paths or parser details.
- No HTTP listener, authentication, source/account authorization, persistence, remote upload or deployment is provided by this unit. Fingerprints bind bytes; they are not authorization or signed parsing attestations.

Runtime and model provisioning are separate operator actions. This module never prepares, updates or downloads them. Rollback is removal of this disconnected processor unit; existing iPad/Worker behavior is unaffected.

The defensive parent validator checks the fixed parser/profile/no-vector strategy, envelope and field shapes, PDF and record hashes, namespace and complete page coverage. It does not independently repeat the Worker's Unicode token estimator. Existing child preparation is authoritative for that boundary; Worker and Swift must still run their final validators before accepting or indexing a response. This result is not permission to bypass either validator.

Cleanup is best effort when the process host itself crashes, is killed or loses its filesystem. A successful return requires this process to have removed its job directory. Deployment needs ephemeral encrypted storage, startup/TTL orphan cleanup and a container filesystem/network/memory boundary; this pure runner alone cannot guarantee physical erasure.
