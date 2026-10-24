"""Bounded, pure metadata enrichment for local Docling chunk envelopes.

The namespace is document/parser identity, never authentication or tenant scope.
Existing text bindings, IDs and schemaVersion remain untouched.
"""
import copy
import hashlib
import json
import math
import re
from structured_chunking import validate_pages, ChunkingError, text_binding, relationships

METADATA_VERSION = 1
MAX_INPUT_BYTES = 32 * 1024 * 1024
MAX_METADATA_BYTES = 16 * 1024 * 1024
MAX_NODES = 300_000
MAX_RECORDS = 20_000
MAX_PROVENANCE = 100_000
MAX_REFS = 100_000
MAX_TEXT = 8_000_000
MAX_ANCESTRY = 64
REF = re.compile(r'[A-Za-z0-9_/#:.\-]{1,512}')
SHA = re.compile(r'[a-f0-9]{64}')


class MetadataError(Exception):
    def __init__(self):
        super().__init__('invalid_metadata')


def invalid():
    raise MetadataError()


def bounded_json(value, limit=MAX_INPUT_BYTES):
    stack = [(value, 0)]
    nodes = size = 0
    while stack:
        current, depth = stack.pop()
        nodes += 1
        if nodes > MAX_NODES or depth > 64:
            invalid()
        if current is None or type(current) is bool:
            size += 5
        elif type(current) in (int, float):
            if not math.isfinite(current) or abs(current) > 1e18:
                invalid()
            size += 32
        elif isinstance(current, str):
            if len(current) > limit:
                invalid()
            size += len(current.encode('utf-8'))
        elif isinstance(current, list):
            if len(current) > MAX_NODES:
                invalid()
            stack.extend((item, depth + 1) for item in current)
        elif isinstance(current, dict):
            if len(current) > MAX_NODES or any(not isinstance(key, str) or len(key) > 512 for key in current):
                invalid()
            stack.extend((item, depth + 1) for pair in current.items() for item in pair)
        else:
            invalid()
        if size > limit:
            invalid()
    try:
        data = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False).encode('utf-8')
    except (TypeError, ValueError, RecursionError, UnicodeError, OverflowError):
        invalid()
    if len(data) > limit:
        invalid()
    return data


def canonical_digest(value, limit=None):
    return hashlib.sha256(bounded_json(value, MAX_METADATA_BYTES if limit is None else limit)).hexdigest()


def text_digest(text):
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


def valid_ref(value):
    return isinstance(value, str) and REF.fullmatch(value) is not None


def validate_element(element, known_pages):
    if (not isinstance(element, dict) or not valid_ref(element.get('elementId')) or
            not isinstance(element.get('kind'), str) or not 1 <= len(element['kind']) <= 64 or
            not isinstance(element.get('text'), str)):
        invalid()
    if element.get('idSource', 'unknown') not in ('docling_self_ref', 'synthetic_unknown', 'unknown'):
        invalid()
    if element.get('level') is not None and (type(element['level']) is not int or not 1 <= element['level'] <= 100):
        invalid()
    if element.get('parentId') is not None and not valid_ref(element['parentId']):
        invalid()
    for key in ('childrenIds', 'captionIds'):
        values = element.get(key)
        if values is not None and (not isinstance(values, list) or len(values) > 1000 or any(not valid_ref(ref) for ref in values)):
            invalid()
    provs = element.get('provenance')
    if not isinstance(provs, list) or len(provs) > 1000:
        invalid()
    for prov in provs:
        if not isinstance(prov, dict) or type(prov.get('pageNumber')) is not int or prov['pageNumber'] not in known_pages:
            invalid()
        span = prov.get('charspan')
        if span is not None and (not isinstance(span, list) or len(span) != 2 or any(type(i) is not int for i in span) or not 0 <= span[0] <= span[1] <= MAX_TEXT):
            invalid()
        bbox = prov.get('bbox')
        if bbox is not None:
            if (not isinstance(bbox, dict) or
                    any(type(bbox.get(key)) not in (int, float) or not math.isfinite(bbox[key]) or abs(bbox[key]) > 1e9 for key in ('l', 't', 'r', 'b')) or
                    ('coordOrigin' in bbox and (not isinstance(bbox['coordOrigin'], str) or len(bbox['coordOrigin']) > 128))):
                invalid()


def heading_path(element, by_id):
    path, seen = [], set()
    current = element['elementId']
    reason = 'complete'
    for _ in range(MAX_ANCESTRY):
        if current in seen:
            reason = 'cycle'
            break
        seen.add(current)
        item = by_id.get(current)
        if item is None:
            reason = 'missing_parent'
            break
        if item['kind'] in ('title', 'section_header'):
            path.append({'elementId': current, 'text': item['text'], 'level': item.get('level')})
        current = item.get('parentId')
        if current is None:
            break
    else:
        reason = 'ancestry_limit'
    path.reverse()
    state = ('explicit' if reason == 'complete' else 'partial') if path else 'unknown'
    return {'state': state, 'reason': reason if path or reason != 'complete' else 'no_explicit_heading', 'items': path}


def metadata_payload(envelope):
    return {'metadataVersion': envelope['metadataVersion'],
            'documentNamespace': envelope['documentNamespace'], 'documentMetadata': envelope['documentMetadata'],
            'pageStates': envelope['pageStates'],
            'chunks': [row['metadata'] for row in envelope['chunks']],
            'protectedElements': [row['metadata'] for row in envelope['protectedElements']],
            'unassignedElements': [row['metadata'] for row in envelope['unassignedElements']]}


def add_metadata(envelope, pages):
    try:
        return _add_metadata(envelope, pages)
    except MetadataError:
        raise
    except (ChunkingError, KeyError, TypeError, ValueError, OverflowError, RecursionError, UnicodeError):
        invalid()


def _add_metadata(envelope, pages):
    bounded_json(envelope)
    bounded_json(pages)
    validate_pages(pages)
    if not isinstance(envelope, dict) or type(envelope.get('schemaVersion')) is not int or envelope.get('schemaVersion') != 1:
        invalid()
    parser, pdf_sha = envelope.get('parser'), envelope.get('pdfSha256')
    if (not isinstance(parser, dict) or set(parser) != {'name', 'version', 'profile'} or
            any(not isinstance(parser[key], str) or not 1 <= len(parser[key]) <= 128 for key in parser) or
            not isinstance(pdf_sha, str) or SHA.fullmatch(pdf_sha) is None):
        invalid()
    if envelope.get('textSha256') != text_binding(pages):
        invalid()
    expected_states = [{'pageNumber': page['pageNumber'], 'needsReview': page['needsReview'], 'needsOCR': page['needsOCR']} for page in pages]
    if bounded_json(envelope.get('pageStates')) != bounded_json(expected_states):
        invalid()
    for key in ('chunks', 'protectedElements', 'unassignedElements'):
        if not isinstance(envelope.get(key), list):
            invalid()
    if sum(len(envelope[key]) for key in ('chunks', 'protectedElements', 'unassignedElements')) > MAX_RECORDS:
        invalid()
    if (not isinstance(envelope.get('strategy'), str) or len(envelope['strategy']) > 128 or
            type(envelope.get('semanticApplied')) is not bool or
            (envelope.get('semanticModel') is not None and (not isinstance(envelope['semanticModel'], str) or not 1 <= len(envelope['semanticModel']) <= 128))):
        invalid()
    if (any(type(envelope.get(key)) is not int or not 0 <= envelope[key] <= 10000
            for key in ('maxEstimatedTokens', 'maxOverlapEstimatedTokens')) or
            type(envelope.get('semanticDistanceThreshold')) not in (int, float) or
            not 0 <= envelope['semanticDistanceThreshold'] <= 2 or
            envelope.get('semanticFallbackReason') not in (None, 'no_vectors', 'not_needed')):
        invalid()
    state_by_page = {row['pageNumber']: row for row in expected_states}
    elements = [e for page in pages for e in page['elements']] + envelope['unassignedElements']
    if len(elements) > MAX_RECORDS or sum(len(e.get('text', '')) for e in elements) > MAX_TEXT:
        invalid()
    by_id, total_prov, total_refs = {}, 0, 0
    for element in elements:
        validate_element(element, state_by_page)
        identity = element['elementId']
        if identity in by_id:
            invalid()
        by_id[identity] = element
        total_prov += len(element['provenance'])
        total_refs += len(relationships(element))
    if total_prov > MAX_PROVENANCE or total_refs > MAX_REFS:
        invalid()
    out = copy.deepcopy(envelope)
    common = {'parser': parser, 'pdfSha256': pdf_sha,
              'strategy': envelope['strategy'], 'semanticApplied': envelope['semanticApplied'],
              'semanticModel': envelope.get('semanticModel'),
              'maxEstimatedTokens': envelope.get('maxEstimatedTokens'),
              'maxOverlapEstimatedTokens': envelope.get('maxOverlapEstimatedTokens'),
              'semanticDistanceThreshold': envelope.get('semanticDistanceThreshold'),
              'semanticFallbackReason': envelope.get('semanticFallbackReason'),
              'namespaceScope': 'document_parser_only_not_authentication',
              'offsetUnit': 'unicode_codepoint', 'provenanceScope': 'element'}
    namespace = canonical_digest({'pdfSha256': pdf_sha, 'parser': parser})
    out['metadataVersion'] = METADATA_VERSION
    out['documentNamespace'] = namespace
    out['documentMetadata'] = copy.deepcopy(common)

    def build(element, start, end, text, unassigned=False, oversized=False):
        page_numbers = sorted({prov['pageNumber'] for prov in element['provenance']})
        needs_review = unassigned or any(state_by_page[p]['needsReview'] for p in page_numbers)
        needs_ocr = any(state_by_page[p]['needsOCR'] for p in page_numbers)
        metadata = {'documentNamespace': namespace, 'kind': element['kind'],
                    'elementId': element['elementId'], 'idSource': element.get('idSource', 'unknown'),
                    'pageNumbers': page_numbers, 'provenanceScope': 'element',
                    'provenance': copy.deepcopy(element['provenance']),
                    'coordinateState': 'known' if element['provenance'] and all(prov.get('bbox') and prov['bbox'].get('coordOrigin') in ('TOPLEFT', 'BOTTOMLEFT') for prov in element['provenance']) else 'unknown',
                    'headingPath': heading_path(element, by_id),
                    'contextRefs': [{**ref, 'resolved': ref['elementId'] in by_id} for ref in relationships(element)],
                    'review': {'needsReview': bool(needs_review), 'needsOCR': needs_ocr,
                               'reviewRequired': bool(needs_review or needs_ocr or oversized), 'oversized': oversized},
                    'source': {'start': start, 'end': end, 'offsetUnit': 'unicode_codepoint', 'textSha256': text_digest(text)}}
        if 'table' in element:
            metadata['tableStructureSha256'] = canonical_digest(element['table'])
        return metadata

    metadata_bytes = 0

    def attach(row, value, local_id):
        nonlocal metadata_bytes
        value['localId'] = local_id
        metadata_bytes += len(bounded_json(value, MAX_METADATA_BYTES))
        if metadata_bytes > MAX_METADATA_BYTES:
            invalid()
        row['metadata'] = value

    seen_chunks = set()
    for row in out['chunks']:
        if not isinstance(row, dict) or row.get('elementId') not in by_id or not isinstance(row.get('chunkId'), str) or row['chunkId'] in seen_chunks:
            invalid()
        seen_chunks.add(row['chunkId'])
        element = by_id[row['elementId']]
        start, end = row.get('start'), row.get('end')
        if (type(start) is not int or type(end) is not int or not 0 <= start < end <= len(element['text']) or
                row.get('text') != element['text'][start:end] or row.get('kind') != element['kind'] or
                row.get('offsetUnit') != 'unicode_codepoint' or type(row.get('pageNumber')) is not int or
                {prov['pageNumber'] for prov in element['provenance']} != {row['pageNumber']} or row.get('provenance') != element['provenance']):
            invalid()
        attach(row, build(element, start, end, row['text']), row['chunkId'])
    for row in out['protectedElements']:
        if not isinstance(row, dict) or not isinstance(row.get('element'), dict):
            invalid()
        element = row['element']
        if by_id.get(element.get('elementId')) != element or type(row.get('oversized')) is not bool or type(row.get('pageNumber')) is not int or {p['pageNumber'] for p in element['provenance']} != {row['pageNumber']}:
            invalid()
        attach(row, build(element, 0, len(element['text']), element['text'], oversized=row['oversized']), element['elementId'])
    for row in out['unassignedElements']:
        attach(row, build(row, 0, len(row['text']), row['text'], unassigned=True), row['elementId'])
    out['metadataSha256'] = canonical_digest(metadata_payload(out))
    bounded_json(out)
    return out


def verify_metadata(envelope):
    """Integrity check only, not authentication or validation against source text."""
    try:
        if not isinstance(envelope, dict):
            return False
        bounded_json(envelope)
        return envelope.get('metadataVersion') == METADATA_VERSION and envelope.get('metadataSha256') == canonical_digest(metadata_payload(envelope))
    except (MetadataError, KeyError, TypeError, ValueError, RecursionError, UnicodeError, OverflowError):
        return False
