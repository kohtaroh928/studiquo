import importlib.util
import hashlib
import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import sys
import tempfile
from types import SimpleNamespace as NS
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("extract_pdf", Path(__file__).with_name("extract_pdf.py"))
extractor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(extractor)


def item(text, page=1, kind="text", extra_prov=()):
    prov = NS(page_no=page, bbox=NS(l=1, t=2, r=30, b=40, coord_origin=NS(value="TOPLEFT")), charspan=(0, len(text)))
    return NS(text=text, label=NS(value=kind), prov=[prov, *extra_prov])


def document(items, count=1):
    return NS(pages={i: NS(page_no=i) for i in range(1, count + 1)},
              iterate_items=lambda: iter((value, 0) for value in items))


class ExtractionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.pdf = self.root / "private.pdf"
        self.pdf.write_bytes(b"%PDF-1.7\nsynthetic fixture")
        self.artifacts = self.root / "models"
        self.artifacts.mkdir()
        self.model = self.artifacts / "synthetic-model"
        self.model.write_bytes(b"synthetic weights")
        self.manifest = {"doclingVersion": extractor.DOCLING_VERSION, "profile": extractor.PROFILE,
                         "files": {"synthetic-model": extractor.file_digest(self.model)}}
        self.write_manifest()
        self.output = self.root / "structure.json"
        self.pages = self.root / "pages.json"

    def write_manifest(self):
        (self.artifacts / "studiquo-artifacts.json").write_text(json.dumps(self.manifest))

    def run_extract(self, doc, **kwargs):
        extractor.extract(str(self.pdf), str(self.artifacts), str(self.output),
                          converter=lambda *_: doc, **kwargs)

    def test_page_order_text_and_provenance_preserved(self):
        doc = document([item("見出し", kind="section_header"), item("条件は一定。"), item("別ページ。", 2)], 2)
        self.run_extract(doc, pages_output=str(self.pages))
        result = json.loads(self.output.read_text())
        pages = json.loads(self.pages.read_text())
        self.assertEqual(result["parser"]["version"], extractor.DOCLING_VERSION)
        self.assertEqual(result["pdfSha256"], hashlib.sha256(self.pdf.read_bytes()).hexdigest())
        self.assertNotIn("sourceHash", result)
        self.assertEqual(pages, [{"pageNumber": 1, "text": "見出し\n\n条件は一定。"}, {"pageNumber": 2, "text": "別ページ。"}])
        self.assertEqual(result["pages"][0]["elements"][0]["kind"], "section_header")
        provenance = result["pages"][0]["elements"][0]["provenance"][0]
        self.assertEqual(provenance["bbox"]["coordOrigin"], "TOPLEFT")
        self.assertEqual(provenance["charspan"], [0, 3])
        for path in [self.output, self.pages]:
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

    def test_table_cells_not_replaced_by_summary(self):
        table = item("", kind="table")
        data = {"num_rows": 2, "num_cols": 1, "table_cells": [{"text": "料金", "start_row_offset_idx": 0}, {"text": "900円", "start_row_offset_idx": 1}]}
        table.data = NS(model_dump=lambda **_: data)
        table.export_to_markdown = lambda **_: "|料金|\n|900円|"
        self.run_extract(document([table]))
        element = json.loads(self.output.read_text())["pages"][0]["elements"][0]
        self.assertEqual(element["table"], data)
        self.assertIn("900円", element["text"])

    def test_hundred_pages_keep_physical_boundaries(self):
        self.run_extract(document([item(f"synthetic page {i}", i) for i in range(1, 101)], 100))
        pages = json.loads(self.output.read_text())["pages"]
        self.assertEqual(len(pages), 100)
        self.assertTrue(all(p["text"] == f"synthetic page {p['pageNumber']}" for p in pages))

    def test_multiple_page_item_is_not_assigned_to_wrong_page(self):
        first = item("ambiguous")
        first.prov.append(item("other", 2).prov[0])
        self.run_extract(document([first], 2))
        result = json.loads(self.output.read_text())
        self.assertEqual(len(result["unassignedElements"]), 1)
        self.assertTrue(all(page["text"] == "" and page["needsReview"] for page in result["pages"]))

    def test_review_required_blocks_ingest_files(self):
        with self.assertRaisesRegex(extractor.ExtractionError, "review_required"):
            self.run_extract(document([], 1), pages_output=str(self.pages))
        self.assertFalse(self.output.exists())
        self.assertFalse(self.pages.exists())

    def test_blank_pages_preserved_and_marked_needs_ocr(self):
        self.run_extract(document([item("text", 2)], 2))
        pages = json.loads(self.output.read_text())["pages"]
        self.assertTrue(pages[0]["needsOCR"])
        self.assertFalse(pages[1]["needsOCR"])

    def test_existing_and_symlink_outputs_never_overwritten(self):
        self.output.write_text("keep")
        with self.assertRaises(extractor.ExtractionError):
            self.run_extract(document([item("text")]))
        self.assertEqual(self.output.read_text(), "keep")
        self.output.unlink()
        self.output.symlink_to(self.pdf)
        with self.assertRaises(extractor.ExtractionError):
            self.run_extract(document([item("text")]))
        self.assertTrue(self.pdf.read_bytes().startswith(b"%PDF"))

    def test_partial_output_failure_cleans_up_only_created_files(self):
        self.pages.write_text("keep")
        with self.assertRaises(extractor.ExtractionError):
            extractor.private_outputs([(self.output, b"synthetic"), (self.pages, b"not allowed")])
        self.assertFalse(self.output.exists())
        self.assertEqual(self.pages.read_text(), "keep")

    def test_local_pdf_only_and_size_limits(self):
        for path in ["https://example.test/private.pdf", "file:///tmp/private.pdf", str(self.root), str(self.model)]:
            with self.assertRaises(extractor.ExtractionError):
                extractor.read_pdf(path)
        link = self.root / "link.pdf"
        link.symlink_to(self.pdf)
        with self.assertRaises(extractor.ExtractionError):
            extractor.read_pdf(str(link))
        with patch.object(extractor, "MAX_PDF_BYTES", 2):
            with self.assertRaises(extractor.ExtractionError):
                extractor.read_pdf(str(self.pdf))

    def test_missing_tampered_or_escaping_artifacts_fail(self):
        self.model.write_bytes(b"tampered")
        with self.assertRaises(extractor.ExtractionError):
            extractor.validate_artifacts(str(self.artifacts))
        for name in ["../private.pdf", "/tmp/escape"]:
            self.manifest["files"] = {name: "a" * 64}
            self.write_manifest()
            with self.assertRaises(extractor.ExtractionError):
                extractor.validate_artifacts(str(self.artifacts))
        self.manifest["files"] = {"link": hashlib.sha256(self.pdf.read_bytes()).hexdigest()}
        (self.artifacts / "link").symlink_to(self.pdf)
        self.write_manifest()
        with self.assertRaises(extractor.ExtractionError):
            extractor.validate_artifacts(str(self.artifacts))

    def test_pipeline_disables_plugins_remote_ocr_and_enrichment(self):
        captured = {}
        class Options:
            def __init__(self, **kwargs):
                captured["options"] = kwargs
        class Converter:
            def __init__(self, **kwargs):
                captured["converter"] = kwargs
            def convert(self, stream, **kwargs):
                captured["source"] = stream
                captured["limits"] = kwargs
                return NS(status=NS(value="success"), errors=[], document="synthetic result")
        modules = {
            "docling.datamodel.base_models": NS(InputFormat=NS(PDF="pdf"), DocumentStream=lambda **kw: NS(**kw)),
            "docling.datamodel.pipeline_options": NS(PdfPipelineOptions=Options),
            "docling.document_converter": NS(DocumentConverter=Converter, PdfFormatOption=lambda **kw: kw),
        }
        with patch.dict(sys.modules, modules), patch.object(extractor.importlib.metadata, "version", return_value=extractor.DOCLING_VERSION):
            self.assertEqual(extractor.convert(self.pdf.read_bytes(), self.artifacts), "synthetic result")
        for flag in ["enable_remote_services", "allow_external_plugins", "do_ocr", "do_formula_enrichment", "do_picture_description"]:
            self.assertIs(captured["options"][flag], False)
        self.assertEqual(captured["converter"]["allowed_formats"], ["pdf"])
        self.assertEqual(captured["source"].name, "input.pdf")
        self.assertEqual(captured["limits"]["max_num_pages"], 1000)

    def test_offline_environment_and_socket_block_restored(self):
        original = socket.create_connection
        old = os.environ.get("HF_HUB_OFFLINE")
        with extractor.offline_library():
            self.assertEqual(os.environ["HF_HUB_OFFLINE"], "1")
            with self.assertRaisesRegex(extractor.ExtractionError, "network_blocked"):
                socket.create_connection(("example.test", 443))
        self.assertIs(socket.create_connection, original)
        self.assertEqual(os.environ.get("HF_HUB_OFFLINE"), old)

    def test_buffered_library_prints_do_not_escape_after_guard(self):
        source = f"import sys;sys.path.insert(0,{str(Path(extractor.__file__).parent)!r});from extract_pdf import offline_library;\nwith offline_library():\n print('SYNTHETIC_PRIVATE_SENTINEL')\nsys.stdout.flush()"
        completed = subprocess.run([sys.executable, "-c", source], capture_output=True, text=True)
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(completed.stdout, "")
        self.assertEqual(completed.stderr, "")

    def test_invalid_provenance_and_nonfinite_coordinates_fail(self):
        for entry in [item("bad", 3), item("bad", True)]:
            with self.assertRaises(extractor.ExtractionError):
                extractor.document_records(document([entry], 2))
        entry = item("bad")
        entry.prov[0].bbox.l = float("nan")
        with self.assertRaises(extractor.ExtractionError):
            extractor.document_records(document([entry]))

    def test_exact_existing_output_pair_refused_before_conversion(self):
        with self.assertRaises(extractor.ExtractionError):
            self.run_extract(document([item("text")]), pages_output=str(self.output))
        self.assertFalse(self.output.exists())

    def test_explicit_null_or_primitive_vectors_never_silently_fallback(self):
        vector_file = self.root / 'vectors.json'
        chunks_file = self.root / 'chunks.json'
        for value in [None, [], 1, 'bad', False]:
            vector_file.write_text(json.dumps(value))
            with self.assertRaisesRegex(extractor.ExtractionError, 'invalid_vectors'):
                self.run_extract(document([item('text')]), chunks_output=str(chunks_file), semantic_vectors=str(vector_file))
            self.assertFalse(self.output.exists())
            self.assertFalse(chunks_file.exists())

    def test_chunks_keep_page_review_and_unassigned_state(self):
        source = item('unassigned')
        source.prov.append(item('other', 2).prov[0])
        chunks_file = self.root / 'chunks.json'
        self.run_extract(document([source], 2), chunks_output=str(chunks_file))
        chunks = json.loads(chunks_file.read_text())
        self.assertTrue(chunks['reviewRequired'])
        self.assertTrue(all(row['needsReview'] and row['needsOCR'] for row in chunks['pageStates']))
        self.assertEqual(len(chunks['unassignedElements']), 1)

    def test_chunks_real_adapter_preserves_ingest_text_exactly(self):
        chunks_file = self.root / 'chunks.json'
        self.run_extract(document([item('original body')]), chunks_output=str(chunks_file), pages_output=str(self.pages))
        self.assertEqual(self.pages.read_text(), '[{"pageNumber":1,"text":"original body"}]\n')
        chunks = json.loads(chunks_file.read_text())
        self.assertEqual(chunks['chunks'][0]['text'], 'original body')
        self.assertEqual(chunks['semanticFallbackReason'], 'no_vectors')

    def test_cli_failure_never_prints_paths_or_private_body(self):
        private = "SYNTHETIC_PRIVATE_SENTINEL"
        completed = subprocess.run([sys.executable, str(Path(extractor.__file__)), "--input", private,
                                    "--artifacts", str(self.artifacts), "--output", str(self.output)], capture_output=True, text=True)
        self.assertEqual(completed.returncode, 1)
        self.assertEqual(completed.stdout, "")
        self.assertEqual(completed.stderr, "docling_extract:invalid_pdf\n")
        self.assertNotIn(private, completed.stderr)


if __name__ == "__main__":
    unittest.main()
