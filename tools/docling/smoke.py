#!/usr/bin/env python3
"""Real Docling smoke with generated synthetic PDF only; no model download."""
import argparse
import json
import os
from pathlib import Path
import stat
import sys
from extract_pdf import DOCLING_VERSION, ExtractionError, QuietParser, extract, private_outputs


def synthetic_pdf():
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>"]
    for number in (1, 2):
        label = b"Page one unique phrase" if number == 1 else b"Page two different phrase"
        content = (b"BT /F1 18 Tf 60 740 Td (Synthetic material) Tj ET\n"
                   b"BT /F1 12 Tf 60 700 Td (" + label + b") Tj ET\n"
                   b"BT /F1 12 Tf 60 660 Td (Conditions apply only to this synthetic page.) Tj ET\n"
                   b"60 600 m 400 600 l 400 500 l 60 500 l h S\n"
                   b"60 550 m 400 550 l S 230 600 m 230 500 l S\n"
                   b"BT /F1 12 Tf 70 570 Td (Category) Tj 170 0 Td (Fee) Tj ET\n"
                   b"BT /F1 12 Tf 70 520 Td (Student) Tj 170 0 Td (900 JPY) Tj ET\n")
        objects.append(f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 7 0 R >> >> /Contents {4 if number == 1 else 6} 0 R >>".encode())
        objects.append(b"<< /Length " + str(len(content)).encode() + b" >>\nstream\n" + content + b"endstream")
    objects.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    data = b"%PDF-1.7\n"
    offsets = [0]
    for index, value in enumerate(objects, 1):
        offsets.append(len(data))
        data += f"{index} 0 obj\n".encode() + value + b"\nendobj\n"
    xref = len(data)
    data += f"xref\n0 {len(objects)+1}\n0000000000 65535 f \n".encode()
    data += b"".join(f"{offset:010d} 00000 n \n".encode() for offset in offsets[1:])
    return data + f"trailer\n<< /Size {len(objects)+1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()


def main(argv=None):
    parser = QuietParser(description="Synthetic PDF only: real offline Docling smoke.")
    parser.add_argument("--artifacts", required=True)
    parser.add_argument("--output-dir", required=True)
    try:
        args = parser.parse_args(argv)
        root = Path(args.output_dir)
        root.mkdir(mode=0o700)  # Existing directories, including symlinks, fail.
        pdf, structured, pages_file, chunks_file = [root / name for name in ("synthetic.pdf", "structured.json", "pages.json", "chunks.json")]
        private_outputs([(pdf, synthetic_pdf())])
        extract(str(pdf), args.artifacts, str(structured), str(pages_file), chunks_output=str(chunks_file))
        result = json.loads(structured.read_text("utf-8"))
        chunks = json.loads(chunks_file.read_text("utf-8"))
        pages = json.loads(pages_file.read_text("utf-8"))
        if len(pages) != 2 or [p["pageNumber"] for p in pages] != [1, 2]:
            raise ExtractionError("smoke_page_failure")
        boundary = ("Page one unique phrase" in pages[0]["text"] and "Page two different phrase" not in pages[0]["text"] and
                    "Page two different phrase" in pages[1]["text"] and "Page one unique phrase" not in pages[1]["text"])
        provenance = all(element["provenance"] and all(prov["pageNumber"] == page["pageNumber"] and prov["bbox"] for prov in element["provenance"])
                         for page in result["pages"] for element in page["elements"])
        private = all(stat.S_IMODE(path.stat().st_mode) == 0o600 for path in (pdf, structured, pages_file, chunks_file))
        body_chunks = chunks["chunks"]
        chunk_verified = bool(body_chunks) and all(chunk["estimatedTokens"] <= 400 and chunk["pageNumber"] in (1, 2) for chunk in body_chunks)
        protected_tables = sum(row["element"]["kind"] == "table" for row in chunks["protectedElements"]) == 2
        if not (boundary and provenance and private and chunk_verified and protected_tables):
            raise ExtractionError("smoke_contract_failure")
        print(json.dumps({"syntheticOnly": True, "parserVersion": DOCLING_VERSION, "pages": 2,
                          "boundaryVerified": boundary, "provenanceVerified": provenance,
                          "privateFilesVerified": private,
                          "chunkContractVerified": chunk_verified, "tablesProtected": protected_tables,
                          "semanticApplied": chunks["semanticApplied"], "semanticFallbackReason": chunks["semanticFallbackReason"],
                          "tableDetected": any(e["kind"] == "table" for p in result["pages"] for e in p["elements"])}))
        return 0
    except Exception:
        sys.stderr.write("docling_smoke:failed\n")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
