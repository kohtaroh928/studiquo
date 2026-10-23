#!/usr/bin/env python3
"""Offline, opt-in single-PDF extraction. Never prints document content."""
from __future__ import annotations

import argparse
import ctypes
from contextlib import contextmanager
import hashlib
import importlib.metadata
import io
import json
import logging
import math
import os
from pathlib import Path
import socket
import stat
import sys

DOCLING_VERSION = "2.139.0"
PROFILE = "native-layout-table-v1"
MAX_PDF_BYTES = 100 * 1024 * 1024
MAX_OUTPUT_BYTES = 32 * 1024 * 1024
MAX_PAGES = 1000
MAX_PAGE_TEXT = 100_000


class ExtractionError(Exception):
    def __init__(self, code):
        self.code = code


def fail(code):
    raise ExtractionError(code)


def local_path(value):
    if not isinstance(value, str) or not value or "://" in value or "\x00" in value:
        fail("invalid_arguments")
    return Path(value)


def read_pdf(value):
    path = local_path(value)
    if path.suffix.lower() != ".pdf":
        fail("invalid_pdf")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as handle:
            info = os.fstat(handle.fileno())
            if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= MAX_PDF_BYTES:
                fail("input_limit")
            data = handle.read(MAX_PDF_BYTES + 1)
    except ExtractionError:
        raise
    except OSError:
        fail("invalid_pdf")
    if len(data) > MAX_PDF_BYTES or not data.startswith(b"%PDF-"):
        fail("invalid_pdf")
    return data


def file_digest(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def validate_artifacts(value):
    root = local_path(value)
    if root.is_symlink() or not root.is_dir():
        fail("artifacts_required")
    manifest_path = root / "studiquo-artifacts.json"
    try:
        if manifest_path.is_symlink() or manifest_path.stat().st_size > 256 * 1024:
            fail("artifacts_invalid")
        manifest = json.loads(manifest_path.read_text("utf-8"))
        if (manifest.get("doclingVersion") != DOCLING_VERSION or
                manifest.get("profile") != PROFILE or
                not isinstance(manifest.get("files"), dict) or
                not 1 <= len(manifest["files"]) <= 1000):
            fail("artifacts_invalid")
        for name, expected in manifest["files"].items():
            relative = Path(name)
            if relative.is_absolute() or not relative.parts or any(p in ("..", ".") for p in relative.parts):
                fail("artifacts_invalid")
            candidate = root
            for part in relative.parts:
                candidate = candidate / part
                if candidate.is_symlink():
                    fail("artifacts_invalid")
            if not candidate.is_file() or not isinstance(expected, str) or file_digest(candidate) != expected:
                fail("artifacts_invalid")
    except ExtractionError:
        raise
    except (OSError, ValueError, TypeError, AttributeError):
        fail("artifacts_invalid")
    return root.resolve()


@contextmanager
def offline_library():
    """No Python network or model fetch; silence Python AND native stdout/stderr.

    This is defense in depth, not an OS sandbox for arbitrary native code.
    """
    updates = {"HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1",
               "HF_HUB_DISABLE_TELEMETRY": "1", "DO_NOT_TRACK": "1",
               "TOKENIZERS_PARALLELISM": "false"}
    previous_env = {key: os.environ.get(key) for key in updates}
    previous_logging = logging.root.manager.disable
    targets = [(socket, "create_connection"), (socket, "getaddrinfo"),
               (socket.socket, "connect"), (socket.socket, "connect_ex"), (socket.socket, "sendto")]
    saved = [(obj, attr, getattr(obj, attr)) for obj, attr in targets]
    descriptors = []
    def blocked(*_args, **_kwargs):
        fail("network_blocked")
    try:
        os.environ.update(updates)
        logging.disable(logging.CRITICAL)
        for obj, attr, _ in saved:
            setattr(obj, attr, blocked)
        # FD redirection also catches library progress bars and native parser errors.
        sys.stdout.flush()
        sys.stderr.flush()
        ctypes.CDLL(None).fflush(None)
        with open(os.devnull, "wb") as sink:
            for descriptor in (1, 2):
                descriptors.append((descriptor, os.dup(descriptor)))
                os.dup2(sink.fileno(), descriptor)
            yield
    finally:
        sys.stdout.flush()
        sys.stderr.flush()
        ctypes.CDLL(None).fflush(None)
        for descriptor, saved_fd in descriptors:
            os.dup2(saved_fd, descriptor)
            os.close(saved_fd)
        for obj, attr, value in saved:
            setattr(obj, attr, value)
        logging.disable(previous_logging)
        for key, old in previous_env.items():
            if old is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = old


def convert(pdf_bytes, artifacts):
    """Only this boundary imports/executes Docling. All inputs remain local."""
    if importlib.metadata.version("docling") != DOCLING_VERSION:
        fail("dependency_version")
    from docling.datamodel.base_models import InputFormat, DocumentStream
    from docling.datamodel.pipeline_options import PdfPipelineOptions
    from docling.document_converter import DocumentConverter, PdfFormatOption
    options = PdfPipelineOptions(
        artifacts_path=artifacts, enable_remote_services=False, allow_external_plugins=False,
        do_ocr=False, do_table_structure=True, do_formula_enrichment=False,
        do_code_enrichment=False, do_picture_classification=False,
        do_picture_description=False, generate_page_images=False,
        generate_picture_images=False, document_timeout=300.0,
    )
    converter = DocumentConverter(allowed_formats=[InputFormat.PDF], format_options={
        InputFormat.PDF: PdfFormatOption(pipeline_options=options),
    })
    # Synthetic name avoids exposing the original path even inside library messages.
    result = converter.convert(DocumentStream(name="input.pdf", stream=io.BytesIO(pdf_bytes)),
                               max_num_pages=MAX_PAGES, max_file_size=MAX_PDF_BYTES)
    if str(getattr(result.status, "value", result.status)) != "success" or result.errors:
        fail("conversion_incomplete")
    return result.document


def bbox_dict(bbox):
    if bbox is None:
        return None
    values = {name: float(getattr(bbox, name)) for name in ("l", "t", "r", "b")}
    if not all(math.isfinite(value) for value in values.values()):
        fail("invalid_structure")
    values["coordOrigin"] = str(getattr(getattr(bbox, "coord_origin", None), "value", "unknown"))
    return values


def document_records(document):
    numbers = sorted(int(number) for number in document.pages)
    if not numbers or numbers != list(range(1, len(numbers) + 1)) or len(numbers) > MAX_PAGES:
        fail("invalid_structure")
    pages = {number: {"pageNumber": number, "text": "", "elements": [], "needsReview": False}
             for number in numbers}
    unassigned = []
    for item_index, (item, _level) in enumerate(document.iterate_items()):
        provenance = []
        for prov in getattr(item, "prov", []):
            number = prov.page_no
            if type(number) is not int or number not in pages:
                fail("invalid_structure")
            span = list(getattr(prov, "charspan", []))
            provenance.append({"pageNumber": number, "bbox": bbox_dict(prov.bbox), "charspan": span})
        kind = str(getattr(getattr(item, "label", None), "value", "unknown"))
        text = getattr(item, "text", "")
        if not isinstance(text, str):
            fail("invalid_structure")
        table = None
        if kind == "table":
            # Preserve cells/row-column structure; never ask a model to summarize the table.
            table = item.data.model_dump(mode="json")
            text = item.export_to_markdown(doc=document)
        def reference(value):
            ref = value if isinstance(value, str) else getattr(value, "cref", None)
            return ref if isinstance(ref, str) and 0 < len(ref) <= 512 else None
        self_ref = reference(getattr(item, "self_ref", None))
        parent_id = reference(getattr(item, "parent", None))
        def references(name):
            values = getattr(item, name, None)
            if values is None:
                return None
            refs = [reference(value) for value in values]
            if any(ref is None for ref in refs):
                fail("invalid_structure")
            return refs
        level = getattr(item, "level", None)
        element = {"kind": kind, "text": text, "provenance": provenance,
                   "elementId": self_ref or f"unknown-item-{item_index}",
                   "idSource": "docling_self_ref" if self_ref else "synthetic_unknown",
                   "parentId": parent_id, "childrenIds": references("children"),
                   "captionIds": references("captions"),
                   "level": level if type(level) is int else None,
                   "relationshipState": "explicit" if parent_id is not None else "unknown"}
        if table is not None:
            element["table"] = table
        page_numbers = {p["pageNumber"] for p in provenance}
        if len(page_numbers) != 1:
            # A whole multi-page item must never be copied onto an arbitrary page.
            unassigned.append(element)
            for number in page_numbers:
                pages[number]["needsReview"] = True
            continue
        number = next(iter(page_numbers))
        pages[number]["elements"].append(element)
        if text:
            pages[number]["text"] += ("\n\n" if pages[number]["text"] else "") + text
    for page in pages.values():
        if len(page["text"].encode("utf-16-le")) // 2 > MAX_PAGE_TEXT:
            fail("output_limit")
        page["needsOCR"] = not bool(page["text"].strip())
    return list(pages.values()), unassigned


def private_outputs(records):
    """Exclusive private creation, with inode-safe cleanup on any partial failure."""
    created = []
    try:
        for path, data in records:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            identity = os.fstat(fd)
            created.append((path, identity.st_dev, identity.st_ino))
            with os.fdopen(fd, "wb") as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
    except BaseException:
        for path, device, inode in created:
            try:
                current = path.lstat()
                if current.st_dev == device and current.st_ino == inode:
                    path.unlink()
            except OSError:
                pass
        fail("output_failed")


def extract(input_path, artifacts_path, output_path, pages_output=None, converter=convert, chunks_output=None, semantic_vectors=None):
    outputs = [local_path(output_path)] + ([local_path(pages_output)] if pages_output is not None else [])
    if chunks_output is not None:
        outputs.append(local_path(chunks_output))
    if semantic_vectors is not None and chunks_output is None:
        fail("invalid_arguments")
    if len({str(path.absolute()) for path in outputs}) != len(outputs):
        fail("output_exists")
    for output in outputs:
        if output.exists() or output.is_symlink() or not output.parent.is_dir():
            fail("output_exists")
    pdf_bytes = read_pdf(input_path)
    artifacts = validate_artifacts(artifacts_path)
    with offline_library():
        document = converter(pdf_bytes, artifacts)
        pages, unassigned = document_records(document)
    result = {"schemaVersion": 1, "parser": {"name": "docling", "version": DOCLING_VERSION, "profile": PROFILE},
              "pdfSha256": hashlib.sha256(pdf_bytes).hexdigest(), "totalPages": len(pages),
              "pages": pages, "unassignedElements": unassigned}
    values = [result]
    if pages_output is not None:
        if unassigned or any(page["needsReview"] or page["needsOCR"] for page in pages):
            fail("review_required")
        values.append([{"pageNumber": page["pageNumber"], "text": page["text"]} for page in pages])
    if chunks_output is not None:
        from structured_chunking import chunk_document, ChunkingError, MAX_VECTOR_BYTES
        payload = None
        if semantic_vectors is not None:
            try:
                vector_path = local_path(semantic_vectors)
                fd = os.open(vector_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                with os.fdopen(fd, "rb") as handle:
                    if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
                        fail("invalid_vectors")
                    raw = handle.read(MAX_VECTOR_BYTES + 1)
                if len(raw) > MAX_VECTOR_BYTES:
                    fail("invalid_vectors")
                payload = json.loads(raw)
                if not isinstance(payload, dict):
                    fail("invalid_vectors")
            except ExtractionError:
                raise
            except Exception:
                fail("invalid_vectors")
        try:
            chunks = chunk_document(pages, payload)
            chunks["parser"] = result["parser"]
            chunks["pdfSha256"] = result["pdfSha256"]
            chunks["unassignedElements"] = unassigned
            chunks["reviewRequired"] = chunks["reviewRequired"] or bool(unassigned)
            from metadata import add_metadata, MetadataError
            try:
                chunks = add_metadata(chunks, pages)
            except MetadataError:
                fail("metadata_failed")
            values.append(chunks)
        except ChunkingError:
            fail("chunking_failed")
    records = []
    for output, value in zip(outputs, values):
        data = (json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":")) + "\n").encode("utf-8")
        if len(data) > MAX_OUTPUT_BYTES:
            fail("output_limit")
        records.append((output, data))
    private_outputs(records)


class QuietParser(argparse.ArgumentParser):
    def error(self, _message):
        fail("invalid_arguments")


def main(argv=None):
    parser = QuietParser(description="Extract one local PDF offline to a new private JSON file.")
    parser.add_argument("--input", required=True)
    parser.add_argument("--artifacts", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--pages-output")
    parser.add_argument("--chunks-output")
    parser.add_argument("--semantic-vectors")
    try:
        args = parser.parse_args(argv)
        extract(args.input, args.artifacts, args.output, args.pages_output, chunks_output=args.chunks_output, semantic_vectors=args.semantic_vectors)
        return 0
    except ExtractionError as error:
        sys.stderr.write("docling_extract:" + error.code + "\n")
    except importlib.metadata.PackageNotFoundError:
        sys.stderr.write("docling_extract:dependency_missing\n")
    except Exception:
        sys.stderr.write("docling_extract:conversion_failed\n")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
