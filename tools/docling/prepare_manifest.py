#!/usr/bin/env python3
"""Explicit local hash inventory after separately authorized model preparation."""
import json
from pathlib import Path
import sys
from extract_pdf import DOCLING_VERSION, PROFILE, ExtractionError, file_digest, local_path, private_outputs


def prepare(value):
    root = local_path(value)
    if root.is_symlink() or not root.is_dir():
        raise ExtractionError("artifacts_required")
    manifest = root / "studiquo-artifacts.json"
    if manifest.exists() or manifest.is_symlink():
        raise ExtractionError("output_exists")
    files = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ExtractionError("artifacts_invalid")
        if path.is_file():
            files[str(path.relative_to(root))] = file_digest(path)
    if not files or len(files) > 1000:
        raise ExtractionError("artifacts_invalid")
    data = {"doclingVersion": DOCLING_VERSION, "profile": PROFILE, "files": files}
    private_outputs([(manifest, (json.dumps(data, sort_keys=True) + "\n").encode("utf-8"))])


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise ExtractionError("invalid_arguments")
        prepare(sys.argv[1])
    except Exception:
        sys.stderr.write("docling_prepare:failed\n")
        raise SystemExit(1)
