#!/usr/bin/env python3
"""Prepare private, bounded structured index batches. Never uploads or reads keys."""
import argparse
import copy
import json
import os
from pathlib import Path
import stat
import sys
import regex
from extract_pdf import private_outputs, QuietParser
from metadata import add_metadata, verify_metadata, bounded_json, MetadataError

ALLOWED = {'text', 'paragraph', 'title', 'section_header', 'list_item', 'footnote', 'caption', 'table', 'formula'}
MAX_BATCH_BYTES = 240 * 1024  # Reserve room below HTTP limit for source/control fields.
MAX_RECORDS = 100
# Mirror the Worker's approximation and ECMAScript whitespace, not a model tokenizer.
JS_WS = r'[\u0009-\u000d\u0020\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]'
TOKEN_PATTERN = regex.compile(r'[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]|[\p{L}\p{N}]+|[^\p{L}\p{N}' + JS_WS[1:-1] + r']|' + JS_WS + '+')


def worker_token_count(text):
    return sum(1 for value in TOKEN_PATTERN.findall(text) if not regex.fullmatch(JS_WS + '+', value))


def reject():
    raise MetadataError()


def prepare_batches(structured, chunks):
    """Validate the complete document before returning any batch to the caller."""
    bounded_json(structured)
    bounded_json(chunks)
    if not isinstance(structured, dict) or not isinstance(chunks, dict): reject()
    pages = structured.get('pages')
    if not isinstance(pages, list) or not pages or len(pages) > 1000: reject()
    if structured.get('totalPages') != len(pages) or [p.get('pageNumber') for p in pages] != list(range(1, len(pages) + 1)): reject()
    if (structured.get('unassignedElements') or chunks.get('unassignedElements') or
            chunks.get('reviewRequired') is not False or
            structured.get('parser') != chunks.get('parser') or structured.get('pdfSha256') != chunks.get('pdfSha256')): reject()
    if not verify_metadata(chunks): reject()
    regenerated = add_metadata(chunks, pages)
    if regenerated['metadataSha256'] != chunks['metadataSha256']: reject()
    common = {'version': 1, 'documentNamespace': chunks['documentNamespace'], 'document': chunks['documentMetadata']}
    by_element = {}
    for row in chunks['chunks']:
        by_element.setdefault(row['elementId'], []).append(row)
    protected = {}
    for row in chunks['protectedElements']:
        identity = row['element']['elementId']
        if identity in protected: reject()
        protected[identity] = row
    output_pages = []
    consumed = set()
    for page in pages:
        if page.get('needsReview') is not False or page.get('needsOCR') is not False or not page['elements']: reject()
        if page.get('text') != '\n\n'.join(e['text'] for e in page['elements'] if e['text']): reject()
        records = []
        for element in page['elements']:
            identity, text = element['elementId'], element['text']
            if element['kind'] not in ALLOWED or not text.strip(): reject()
            if element['kind'] in ('text', 'paragraph'):
                rows = sorted(by_element.get(identity, []), key=lambda r: r['start'])
                cursor = 0
                for row in rows:
                    if row['start'] > cursor: reject()
                    cursor = max(cursor, row['end'])
                if not rows or cursor != len(text): reject()
                if identity in protected: reject()
            else:
                if identity in by_element or identity not in protected: reject()
                rows = [protected[identity]]
            consumed.add(identity)
            for row in rows:
                metadata = row['metadata']
                if any(metadata['review'].values()) or metadata['pageNumbers'] != [page['pageNumber']]: reject()
                body = row.get('text', row.get('element', {}).get('text'))
                if not isinstance(body, str) or not body.strip() or len(body.encode('utf-16-le')) // 2 > 6000 or worker_token_count(body) > 500: reject()
                if len(metadata['provenance']) > 16 or len(metadata['contextRefs']) > 32: reject()
                headings = metadata['headingPath']['items']
                if len(headings) > 16 or any(len(h['text'].encode('utf-16-le')) // 2 > 300 for h in headings): reject()
                if len(' / '.join(h['text'] for h in headings).encode('utf-16-le')) // 2 > 1000: reject()
                if len(bounded_json(metadata)) > 16 * 1024: reject()
                records.append({'text': body, 'metadata': copy.deepcopy(metadata)})
        if len(records) > MAX_RECORDS or not records: reject()
        if not isinstance(page.get('text'), str) or len(page['text'].encode('utf-16-le')) // 2 > 100000: reject()
        output_pages.append({'pageNumber': page['pageNumber'], 'text': page['text'], 'structured': {'version': 1, 'records': records}})
    if consumed != set(by_element) | set(protected): reject()
    batches, current = [], []
    for page in output_pages:
        proposed = {'structure': common, 'totalPages': len(pages), 'pages': current + [page]}
        if len(current) == 5 or len(bounded_json(proposed)) > MAX_BATCH_BYTES:
            if not current: reject()
            batches.append({'structure': common, 'totalPages': len(pages), 'pages': current})
            current = []
        current.append(page)
        if len(bounded_json({'structure': common, 'totalPages': len(pages), 'pages': current})) > MAX_BATCH_BYTES: reject()
    if current: batches.append({'structure': common, 'totalPages': len(pages), 'pages': current})
    result = {'version': 1, 'integration': 'prepared_only_no_upload', 'batches': batches}
    bounded_json(result)
    return result


def read_private_json(value):
    path = Path(value)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as handle:
        if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode): reject()
        data = handle.read(32 * 1024 * 1024 + 1)
    if len(data) > 32 * 1024 * 1024: reject()
    return json.loads(data)


def main():
    try:
        parser = QuietParser(description=__doc__)
        parser.add_argument('--structured', required=True)
        parser.add_argument('--chunks', required=True)
        parser.add_argument('--output', required=True)
        args = parser.parse_args()
        result = prepare_batches(read_private_json(args.structured), read_private_json(args.chunks))
        private_outputs([(Path(args.output), bounded_json(result) + b'\n')])
        return 0
    except Exception:
        sys.stderr.write('docling_index_payload:invalid_payload\n')
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
