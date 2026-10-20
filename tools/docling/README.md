# Docling local PDF adapter

The optional structured chunk output also carries versioned metadata; see
[`RAG_METADATA_ADDITION.md`](../../docs/RAG_METADATA_ADDITION.md) for its
contract and integration limits. Metadata remains private alongside the source
text. Element bounding boxes do not become precise chunk bounding boxes.

A developer-only, offline extraction boundary. It does not change the iPad,
Worker, indexing algorithm, Cloudflare data, or production flags. It takes one
explicit local PDF, retains physical page numbers and layout provenance, and
writes to new private files. It never uploads documents or calls an LLM.

## Preparation (separate from extraction)

Use Python 3.12 in a dedicated virtual environment. Installing dependencies and
fetching model weights are **explicit preparation steps with network access**;
the extraction command never performs them. `requirements.txt` pins the Docling
release. `requirements.lock.txt` records the complete resolved environment used
for the macOS arm64 / Python 3.12 smoke; it is platform-specific and does not
include wheel hashes. Re-review/resolve for other platforms before deployment.

```sh
python3.12 -m venv /private/tmp/studiquo-docling-env
/private/tmp/studiquo-docling-env/bin/python -m pip install -r tools/docling/requirements.lock.txt
```

Prepare the layout and TableFormer weights into an explicit local directory
using the pinned release's explicit command (no user's document is needed):

```sh
/private/tmp/studiquo-docling-env/bin/docling-tools models download layout tableformer \
  --output-dir /private/tmp/studiquo-docling-models
```
Do not use arbitrary untrusted model directories. After reviewing the complete
artifacts, create the local SHA-256 inventory (no network):

```sh
/private/tmp/studiquo-docling-env/bin/python tools/docling/prepare_manifest.py /private/tmp/studiquo-docling-models
```

The inventory refuses symlinks/existing inventories. It records the profile,
Docling release, relative artifact filenames and their SHA-256 digests.
Extraction validates every declared file. The inventory is integrity metadata,
not a model authenticity/signature check and not proof that every required
pipeline artifact was prepared; missing pipeline files fail offline.

## Extraction

Create a private working directory outside the repository, then choose new
output filenames. Both output files contain private document text.

```sh
mkdir -m 700 /private/tmp/studiquo-docling-example
/private/tmp/studiquo-docling-env/bin/python tools/docling/extract_pdf.py \
  --input /absolute/local/document.pdf \
  --artifacts /private/tmp/studiquo-docling-models \
  --output /private/tmp/studiquo-docling-example/structured.json \
  --pages-output /private/tmp/studiquo-docling-example/pages.json
```

`--pages-output` is optional. A successful run is silent. Failures use only fixed
`docling_extract:<code>` on stderr; no body, source path or library traceback.
Existing destinations, final symlinks, URLs and input directories are rejected.
Files are exclusively created with mode `0600`; partial writes are removed by
matching the created inode. Parent directories must already exist.

Input is capped at 100 MiB / 1,000 physical pages; each page has at most 100,000
UTF-16 code units and each output is at most 32 MiB. The conversion pipeline has
a 300-second document timeout; this is Docling's cooperative timeout, not an OS
kill/resource limit. Use an external process/container time and memory limit for
untrusted inputs or large documents.

## Output and existing ingest contract

`structured.json` contains `schemaVersion`, parser name/version/profile,
`pdfSha256`, `totalPages`, `pages`, and `unassignedElements`. Each page contains
`pageNumber`, ordered `text`, `elements`, `needsReview`, and `needsOCR`.
Elements retain Docling's label as `kind`, text, page/character-span provenance,
bounding box coordinates **and coordinate origin**. Tables additionally retain
row/column/cell structure rather than an LLM-generated summary.

`pages.json` is the existing ingest-compatible array:

```json
[{"pageNumber":1,"text":"extracted page text"}]
```

It can be supplied as `pagesFile` to
`mcp-server/scripts/rag-quality/real-material-evaluate.ts` or an explicit local
indexing preparation step. No upload is performed here. The optional pages
export fails with `review_required` if pages are blank or elements cannot be
attributed to exactly one page; rerun **without** `--pages-output` to inspect the
structured result privately. Multi-page/unprovenanced item text is retained in
`unassignedElements`, never copied onto an arbitrary citation page.

**`pdfSha256` is file provenance only.** This adapter deliberately does not emit
`sourceHash`/`pageHash`. Existing indexing hashes normalized extracted page text;
compute those in the existing ingest path. A different parser may produce
different text/order and therefore a different index generation even for the
same PDF. Do not substitute the raw PDF digest for the existing source hash.

## Scope and safety limits

The initial `native-layout-table-v1` profile runs local layout and table
structure models, with OCR, formula/code enrichment and picture descriptions
**off**. It does not yet replace Vision OCR, establish Japanese scan accuracy,
or claim formula understanding. Blank pages are marked `needsOCR`.

`enable_remote_services=False`, `allow_external_plugins=False`, explicit local
`artifacts_path`, offline Hugging Face/Transformers environment settings and
Python socket guards prevent routine remote services/model fetches. The guard
is **not an OS sandbox for arbitrary native extensions**. For a strict network
boundary run in a network-disabled container/OS sandbox, with reviewed
read-only dependencies/artifacts and only input/output directories mounted.
Do not run concurrent conversions in this CLI process: its log/socket isolation
is process-wide. Python/native stdout/stderr are suppressed during imports and
conversion; only fixed error codes leave the boundary.

## Tests

```sh
python3 -m unittest discover -s tools/docling -p 'test_*.py'
```

Unit tests use synthetic text/documents and an injected converter; they verify
page boundaries (including 100 pages), table cell retention, provenance,
ambiguous/blank-page review, private/no-overwrite output, artifact integrity,
offline configuration and fixed error output. They do not measure Docling's
actual layout/OCR quality. Actual dependency/model/synthetic-PDF smoke results
must be reported separately; never call mocked conversion a real smoke test.

Official references (checked 2026-10-16):

- [Offline artifacts and remote-service options](https://docling-project.github.io/docling/usage/advanced_options/)
- [Pinned DocumentConverter API](https://github.com/docling-project/docling/blob/v2.139.0/docling/document_converter.py)
- [Pinned pipeline options](https://github.com/docling-project/docling/blob/v2.139.0/docling/datamodel/pipeline_options.py)
- [Pinned package release](https://pypi.org/project/docling/2.139.0/)

## Real synthetic smoke

With the dependencies and artifacts explicitly prepared, this command creates
its **own synthetic two-page PDF**, runs the real converter offline and emits
metadata only. It refuses an existing output directory and never accepts a
user document:

```sh
/private/tmp/studiquo-docling-env/bin/python tools/docling/smoke.py \
  --artifacts /private/tmp/studiquo-docling-models \
  --output-dir /private/tmp/studiquo-docling-smoke-new
```

See [VALIDATION.md](VALIDATION.md) for the checked result and remaining limits.


## Optional structured chunk adapter (local evaluation only)

Add `--chunks-output /absolute/private/new-chunks.json` to `extract_pdf.py`.
This leaves the existing `pages.json` text unchanged. **The Worker still splits
`pages.text` itself: it does not consume this chunk file.** This is not a
production ingestion switch or a measured retrieval-quality improvement.

The structure boundary is each Docling element on its original physical page.
Only `text` and `paragraph` are body kinds. Headings, titles, lists, footnotes and
captions remain separate protected/context elements because their scope should
not be inferred by concatenating them into nearby paragraphs. Tables, pictures
and formulas are never recursively split or mixed into body chunks; oversized
ones are retained with `oversized: true` for review. Unknown labels also remain
protected. A large atom needs a later element-specific strategy, not a silent
text truncation.

For sufficiently long body elements (at least 120 estimated tokens and two
sentence units), optional semantic splitting compares **adjacent sentence
vectors**: cosine distance at least **0.35** starts a new semantic region.
Then each region uses recursive boundaries in this priority: blank line → line
break → sentence boundary → whitespace → Unicode character. Each body chunk is
at most **400 estimated tokens including overlap**, with at most **65 estimated
tokens of overlap** inside its semantic region. No overlap crosses a semantic
region, element or physical page. These are explicit language-independent
estimates (ASCII character = 1/4 token, other code point = 1 token), not a model
specific tokenizer or an accuracy claim.

Chunks retain original `elementId`, `pageNumber`, exact original substring and
`start/end` in **Unicode code-point indices** (not UTF-16 or bytes), provenance,
heading references, and explicit parent/children/caption references. No nearest
caption or formula is guessed. Heading refs use only explicit parent ancestry;
if the Docling parent is a body/group with no heading ancestor, heading state
stays `unknown`. Unresolved explicit refs are marked `resolved: false`.
Docling `self_ref` is retained; missing IDs use a deterministic extraction-order
fallback with `idSource: synthetic_unknown`, not a claimed persistent source ID.
Missing relationships/level are null/unknown. Raw `self_ref`/parent/group IDs are
not cross-document IDs.

### Generate the exact units for an existing offline embedding encoder

Do not invent character offsets or hashes. First extract structured JSON, then:

```sh
/private/tmp/studiquo-docling-env/bin/python tools/docling/semantic_manifest.py \
  --structured /absolute/private/structured.json \
  --output /absolute/private/new-semantic-units.json
```

The private manifest contains the complete text binding and sentence units with
exact original text, page, element ID, offsets and SHA-256. It has `model`,
`dimension` and per-unit `vector` set to null. Feed these exact unit texts to a
**separately prepared local embedding encoder**; in a new private file fill its
actual model label, common dimension, and each vector while preserving unit
order/identity/hash. This tool neither supplies an encoder nor downloads one.
The programmatic boundary is `semantic_manifest.manifest_for_pages(pages)`.
Its output is directly accepted after filling those fields; tests exercise that
round trip with explicit synthetic vectors.

Then rerun extraction to new filenames with:

```sh
/private/tmp/studiquo-docling-env/bin/python tools/docling/extract_pdf.py \
  --input /absolute/local/document.pdf \
  --artifacts /private/tmp/studiquo-docling-models \
  --output /absolute/private/structured-new.json \
  --chunks-output /absolute/private/chunks-with-vectors.json \
  --semantic-vectors /absolute/private/filled-vectors.json
```

The provided vectors must bind to all eligible units of the exact extraction:
text SHA, element/page/offsets and unit SHA must match. The model label must be
nonblank and at most 128 characters. Missing/malformed/mismatched vectors,
zero/NaN/invalid dimension vectors are rejected, never silently ignored.
No vectors: `semanticApplied: false`, `semanticFallbackReason: no_vectors`.
Valid vectors but no eligible units: fallback reason `not_needed`. Synthetic
vector tests verify dispatch/segmentation logic, **not learned semantic quality**.

Bounds: 1,000 pages, 20,000 elements/eligible sentence units/body chunks,
8,000,000 total element text code points, vector dimension 1–4,096 and at most
2,000,000 vector components. Vector file and each output are at most 32 MiB.
The same private exclusive creation and offline/no-key rules apply. Conversion
has the existing cooperative timeout; use a process/resource sandbox for hard
limits. Structures/provenance that cannot be safely assigned remain in
`unassignedElements`, not fabricated chunks.


Semantic scope is **inside a single body element only**, with at least 120
estimated tokens and multiple sentence units. It does not semantically merge
separate paragraphs, repack several small paragraphs into a target-sized
chunk, or infer a heading from nearby reading order. Those remain later
quality/performance work. Chunk files retain `pageStates` (including blank-page
`needsOCR` and ambiguous `needsReview`) and propagate `reviewRequired` into body
chunks and protected elements. Unassigned elements also force the top-level
review flag; a chunks-only export never silently loses those review states.

Both page review flags must be explicit booleans; missing flags fail validation
instead of being treated as safe. Chunk provenance is labeled
`provenanceScope: element`: its bbox/Docling charspan describe the original
element, while chunk start/end describe the exact substring within that element.
The adapter does not fabricate a smaller geometric bbox for each text slice.


## Prepare structured Worker index batches (no upload)

After producing structured.json and chunks.json, prepare a private batch manifest:

```sh
/private/tmp/studiquo-docling-env/bin/python tools/docling/index_payload.py \
  --structured /absolute/private/structured.json \
  --chunks /absolute/private/chunks.json \
  --output /absolute/private/index-batches.json
```

The complete document is checked before the new0600 output is created. It rejects
unassigned/review/OCR/blank/picture/unknown/oversized elements and missing body
coverage. Batches carry at most5 pages and240KiB, reserving space below the
512KiB API request limit. The existing pinned regex package mirrors the Worker's
500-token approximation and ECMAScript whitespace; this is not a model tokenizer.
No text is silently dropped or re-split to pass these limits.

Each batch contains structure, totalPages and pages. An authorized caller must
supply its actual sourceId/title/kind/folderId/sourceHash and, for managed sources,
the current control proof using the existing API. The raw PDF digest is not the
existing text-based sourceHash. No automatic upload or key lookup is included.
The new Worker requires the0009 metadata migration before accepting this input;
legacy pages remain supported on older schemas. Never send it to an old Worker
that silently ignores new fields. Revalidate each complete prepared batch with
the Worker validator before building a transport; source/control fields and the
final HTTP limit still apply. Table Markdown is indexed; original table cell
structure remains in local structured.json, with only its digest in the batch.
