"""Fixed private child entry. All diagnostics are discarded by the runner."""
import json
import os
from pathlib import Path
import resource
import sys


def main():
    os.umask(0o077)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_CPU, (120, 120))
    resource.setrlimit(resource.RLIMIT_FSIZE, (16 * 1024 * 1024, 16 * 1024 * 1024))
    if len(sys.argv) != 3:
        return 1
    job, artifacts = map(Path, sys.argv[1:])
    # This code location is deployment-owned; never accept a module path from a request.
    tools = Path(__file__).resolve().parents[2] / 'tools' / 'docling'
    sys.path.insert(0, str(tools))
    import extract_pdf
    from index_payload import prepare_batches
    from extract_pdf import private_outputs
    extract_pdf.MAX_PAGES = 20
    extract_pdf.MAX_PDF_BYTES = 10 * 1024 * 1024
    extract_pdf.MAX_OUTPUT_BYTES = 16 * 1024 * 1024
    structured_path, chunks_path = job / 'structured.json', job / 'chunks.json'
    extract_pdf.extract(str(job / 'input.pdf'), str(artifacts), str(structured_path), chunks_output=str(chunks_path))
    with structured_path.open(encoding='utf-8') as stream:
        structured = json.load(stream)
    with chunks_path.open(encoding='utf-8') as stream:
        chunks = json.load(stream)
    manifest = prepare_batches(structured, chunks)
    output = json.dumps(manifest, ensure_ascii=False, allow_nan=False, separators=(',', ':')).encode('utf-8')
    if len(output) > 4 * 1024 * 1024:
        return 1
    private_outputs([(job / 'prepared.json', output)])
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception:
        raise SystemExit(1) from None
