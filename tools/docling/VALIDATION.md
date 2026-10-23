# Local Docling validation — 2026-10-16

Scope: developer-only tools under `tools/docling/`. No Worker/iPad production
path, database, API key, upload, deployment or production flag was changed.
No user PDF was opened; the actual smoke generated its own synthetic PDF.

## Verified

- 16 Python unit tests passed with the dedicated Python 3.12 environment.
- Actual dependency versions: Python 3.12.14, macOS arm64, Docling 2.139.0,
  docling-core 2.101.1. Complete resolved versions are in
  `requirements.lock.txt` (102 pinned distributions, no wheel hashes).
- Explicit model preparation: Docling's `layout tableformer` model set,
  approximately 669 MiB of local artifacts. Dependency/model download was a
  separate authorized preparation step; normal extraction did not download.
- Real offline conversion of a generated two-page PDF succeeded:
  2 physical pages, 8 ordered elements, 2 tables, 0 unassigned elements.
- The original page-specific phrases remained on the correct pages;
  provenance bounding boxes and page numbers were retained.
- Private structured JSON and ingest-compatible pages JSON were generated.
  Both plus the synthetic input had permission `0600` inside a new `0700`
  directory. The smoke emitted only booleans, counts and parser version.
- Extraction used explicit artifacts, remote services/plugins disabled,
  Hugging Face/Transformers offline settings and a Python socket guard.
- Fixed failure codes, URL/directory/symlink rejection, artifact hash checking,
  no-overwrite behavior, partial-output cleanup, logging suppression, 100-page
  page-boundary preservation and ambiguous provenance handling have unit tests.

Smoke metadata result:

```json
{"syntheticOnly":true,"parserVersion":"2.139.0","pages":2,"boundaryVerified":true,"provenanceVerified":true,"privateFilesVerified":true,"tableDetected":true}
```

Local private artifacts used for this validation:
`/private/tmp/studiquo-docling-smoke-01/`; summary only:
`/private/tmp/docling-smoke-result.log`. These are not repository fixtures or
production data and are not uploaded anywhere.

## Not established by this check

- OCR, Japanese scanned PDFs, handwriting or formula recognition quality.
  The initial profile explicitly disables OCR/formula/code enrichment.
- Real 100-page Docling inference throughput/memory/accuracy. The 100-page
  boundary test uses an injected synthetic converter; actual inference smoke
  covers two pages only.
- Automatic iPad registration or Worker integration. The pages array is a local
  adapter output; existing ingest must calculate its own text-based hashes.
- Cross-platform reproducibility, wheel provenance, dependency/model license
  audit or vulnerability audit. The lock is for this macOS arm64/Python 3.12
  environment; model authenticity is not guaranteed by a locally generated
  inventory.
- Hard isolation of arbitrary native code. Python socket guards and offline
  options are defense in depth, not a substitute for an OS/container network
  and resource sandbox when handling untrusted inputs.
- A cooperative Docling timeout is not a hard process kill/memory limit.

Rollback: remove/stop invoking these optional local tools; no server migration
or persistent application change requires reversal. Existing extraction remains
available. Broader ingestion or production adoption needs a separate reviewed
change and real material quality evaluation.


## Structured chunk extension — 2026-10-16

- 34 Python tests passed after independent review corrections, including page
  state propagation, explicit JSON null/primitive vector-file rejection and
  shared global/duplicate-identity validation for the semantic manifest.
- Pure structure/recursive tests verify exact substring offsets, complete
  original-text coverage, at most 400 estimated tokens / 65 overlap, Unicode
  fallback and no cross-page/element/semantic-region overlap.
- Explicit synthetic vectors exercise cosine threshold cuts, identical-vector
  continuation and invalid/missing/hash-mismatched vector rejection. This is
  algorithm verification, not real embedding/semantic quality measurement.
- The exact sentence-unit manifest generator supplies text, offsets and hashes
  for a separately prepared offline encoder; no embedding model was added,
  invoked or downloaded for this extension.
- Real two-page synthetic Docling smoke now additionally emits chunks and
  verifies table protection/body chunk bounds. The result explicitly reports
  `semanticApplied: false`, `semanticFallbackReason: no_vectors`.
- Only text/paragraph are body kinds. Structural headings/lists/footnotes/
  captions, tables/pictures/formulas and unknown kinds remain protected.
- Same-element long-body semantic splitting only; no semantic merging across
  paragraphs or packing small paragraphs together. These are accepted limits.
- Worker ingestion still re-splits `pages.text`; this optional local chunks
  output is **not consumed by the Worker or the iPad automatic pipeline**.
- Real synthetic extension artifacts: `/private/tmp/studiquo-docling-chunks-smoke-03/`;
  metadata-only log: `/private/tmp/docling-chunks-smoke-03.log`.


## Metadata extension — 2026-10-17

Python43 tests passed (9 metadata + 34 prior). Real offline two-page synthetic
smoke retained 4 body chunks / 4 protected elements including 2 tables. Metadata
digest, element coordinate origins and private0600 files verified separately.
No user PDF, additional model download, API call or Worker change.
See docs/RAG_METADATA_ADDITION.md for limits and outstanding DB integration.


## Structured index preparation — 2026-10-17

Python49 tests passed. Exporter checks complete document coverage before private
5-page/240KiB batch generation. Worker and exporter share token/heading bounds
(approximate, not model-tokenizer counts); punctuation/heading boundary regressions
were added after independent review. Existing pinned regex is used, no new
dependency/model download. Two real synthetic Docling pages produced8 records
accepted by Worker validation and stored in local SQLite with citation metadata.
Worker all1722 tests passed, independent final JS15/Python49 passed. No upload,
real AI, key access, remote migration, deployment or iPad hookup.
