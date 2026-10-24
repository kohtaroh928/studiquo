#!/usr/bin/env python3
"""Create exact local sentence units for a separately prepared offline encoder."""
import json
import os
import stat
import sys
from extract_pdf import QuietParser, ExtractionError, local_path, private_outputs, MAX_OUTPUT_BYTES
from structured_chunking import validate_pages, text_binding, semantic_units


def manifest_for_pages(pages):
    validate_pages(pages)
    by_id = {element['elementId']: element for page in pages for element in page['elements']}
    return {'schemaVersion': 1, 'textSha256': text_binding(pages), 'model': None, 'dimension': None,
            'units': [{**unit, 'text': by_id[unit['elementId']]['text'][unit['start']:unit['end']], 'vector': None}
                      for unit in semantic_units(pages)]}


def main(argv=None):
    parser = QuietParser(description='Generate private semantic unit manifest; never embeds or downloads.')
    parser.add_argument('--structured', required=True)
    parser.add_argument('--output', required=True)
    try:
        args = parser.parse_args(argv)
        source = local_path(args.structured)
        fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as handle:
            if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
                raise ExtractionError('invalid_structure')
            raw = handle.read(MAX_OUTPUT_BYTES + 1)
        if len(raw) > MAX_OUTPUT_BYTES:
            raise ExtractionError('input_limit')
        document = json.loads(raw)
        if not isinstance(document, dict) or document.get('schemaVersion') != 1:
            raise ExtractionError('invalid_structure')
        payload = manifest_for_pages(document['pages'])
        data = (json.dumps(payload, ensure_ascii=False, allow_nan=False, separators=(',', ':')) + '\n').encode('utf-8')
        if len(data) > MAX_OUTPUT_BYTES:
            raise ExtractionError('output_limit')
        private_outputs([(local_path(args.output), data)])
        return 0
    except Exception:
        sys.stderr.write('docling_semantic_manifest:failed\n')
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
