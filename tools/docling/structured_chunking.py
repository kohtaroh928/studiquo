"""Pure local structure/semantic/recursive adapter; no embedding or network calls."""
import hashlib
import json
import math
import re

MAX_TOKENS = 400
OVERLAP_TOKENS = 65
MAX_UNITS = 20_000
MAX_ELEMENTS = 20_000
MAX_TEXT_CHARS = 8_000_000
MAX_DIMENSIONS = 4096
MAX_VECTOR_COMPONENTS = 2_000_000
MAX_VECTOR_BYTES = 32 * 1024 * 1024
BODY_KINDS = frozenset({'text', 'paragraph'})
STRUCTURAL_KINDS = frozenset({'section_header', 'title', 'list_item', 'footnote', 'caption'})
PROTECTED_KINDS = frozenset({'table', 'picture', 'formula'})
SEMANTIC_MIN_TOKENS = 120
SEMANTIC_THRESHOLD = 0.35


class ChunkingError(Exception):
    pass


def digest(value):
    return hashlib.sha256(value.encode('utf-8')).hexdigest()


def weight(char):
    return 1 if ord(char) < 128 else 4


def estimated_tokens(text):
    return (sum(weight(char) for char in text) + 3) // 4


def sentence_spans(text):
    start = 0
    spans = []
    for match in re.finditer(r'[。！？.!?](?:\s+|(?=[^\x00-\x7f])|$)|\n\n+', text):
        end = match.end()
        if end > start:
            spans.append((start, end))
            start = end
    if start < len(text):
        spans.append((start, len(text)))
    return spans


def semantic_units(pages):
    units = []
    for page in pages:
        for element in page['elements']:
            if element['kind'] not in BODY_KINDS or estimated_tokens(element['text']) < SEMANTIC_MIN_TOKENS:
                continue
            spans = sentence_spans(element['text'])
            if len(spans) < 2:
                continue
            for start, end in spans:
                units.append({'elementId': element['elementId'], 'pageNumber': page['pageNumber'],
                              'start': start, 'end': end, 'sha256': digest(element['text'][start:end])})
                if len(units) > MAX_UNITS:
                    raise ChunkingError('unit_limit')
    return units


def text_binding(pages):
    return digest(json.dumps([{'pageNumber': page['pageNumber'], 'elements':
                              [{'elementId': e['elementId'], 'kind': e['kind'], 'text': e['text']} for e in page['elements']]}
                             for page in pages], ensure_ascii=False, separators=(',', ':')))


def validate_vectors(payload, pages, units):
    if not isinstance(payload, dict) or payload.get('schemaVersion') != 1 or payload.get('textSha256') != text_binding(pages):
        raise ChunkingError('invalid_vectors')
    model = payload.get('model')
    if not isinstance(model, str) or not model.strip() or len(model) > 128:
        raise ChunkingError('invalid_vectors')
    dimension, rows = payload.get('dimension'), payload.get('units')
    if type(dimension) is not int or not 1 <= dimension <= MAX_DIMENSIONS or not isinstance(rows, list) or len(rows) != len(units) or dimension * len(units) > MAX_VECTOR_COMPONENTS:
        raise ChunkingError('invalid_vectors')
    vectors = []
    for expected, row in zip(units, rows):
        if not isinstance(row, dict) or any(type(row.get(key)) is not type(value) or row.get(key) != value for key, value in expected.items()):
            raise ChunkingError('invalid_vectors')
        vector = row.get('vector')
        if (not isinstance(vector, list) or len(vector) != dimension or
                any(type(v) not in (int, float) or not math.isfinite(v) or abs(v) > 1e10 for v in vector)):
            raise ChunkingError('invalid_vectors')
        norm = math.sqrt(sum(v * v for v in vector))
        if norm == 0:
            raise ChunkingError('invalid_vectors')
        vectors.append([v / norm for v in vector])
    return vectors


def maximum_end(text, start, end, budget=MAX_TOKENS):
    total = 0
    for index in range(start, end):
        total += weight(text[index])
        if total > budget * 4:
            return index
    return end


def recursive_end(text, start, hard_end, level=0):
    # Recurse through boundary strengths; characters are the final lossless fallback.
    patterns = [r'\n\s*\n', r'\n', r'[。！？.!?](?:\s+|(?=[^\x00-\x7f])|$)', r'\s+']
    if level == len(patterns):
        return hard_end
    candidates = [match.end() + start for match in re.finditer(patterns[level], text[start:hard_end])]
    # Avoid a weak early boundary forcing tiny, almost entirely overlapping chunks.
    candidates = [end for end in candidates if end > start and estimated_tokens(text[start:end]) > OVERLAP_TOKENS]
    return candidates[-1] if candidates else recursive_end(text, start, hard_end, level + 1)


def overlap_start(text, start, end):
    total = 0
    position = end
    while position > start and total + weight(text[position - 1]) <= OVERLAP_TOKENS * 4:
        position -= 1
        total += weight(text[position])
    return max(start + 1, position)


def split_ranges(text, region_start, region_end):
    start = region_start
    while start < region_end:
        hard_end = maximum_end(text, start, region_end)
        end = region_end if hard_end == region_end else recursive_end(text, start, hard_end)
        if end <= start:
            raise ChunkingError('invalid_split')
        yield start, end
        if end == region_end:
            break
        start = overlap_start(text, start, end)


def relationships(element):
    result = []
    if isinstance(element.get('parentId'), str):
        result.append({'role': 'parent', 'elementId': element['parentId']})
    for name, role in [('childrenIds', 'child'), ('captionIds', 'caption')]:
        if isinstance(element.get(name), list):
            result.extend({'role': role, 'elementId': value} for value in element[name])
    return result


def validate_pages(pages):
    if not isinstance(pages, list) or not 1 <= len(pages) <= 1000:
        raise ChunkingError('invalid_structure')
    seen = set()
    element_ids = set()
    element_count = 0
    total_characters = 0
    valid_ref = lambda value: isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9_/#:.\-]{1,512}', value) is not None
    for page in pages:
        if not isinstance(page, dict) or type(page.get('pageNumber')) is not int or not 1 <= page['pageNumber'] <= 1000 or page['pageNumber'] in seen or not isinstance(page.get('elements'), list):
            raise ChunkingError('invalid_structure')
        seen.add(page['pageNumber'])
        if any(type(page.get(flag)) is not bool for flag in ('needsReview', 'needsOCR')):
            raise ChunkingError('invalid_structure')
        element_count += len(page['elements'])
        if element_count > MAX_ELEMENTS:
            raise ChunkingError('input_limit')
        for element in page['elements']:
            if not isinstance(element, dict) or not valid_ref(element.get('elementId')) or not isinstance(element.get('kind'), str) or not 1 <= len(element['kind']) <= 64 or not isinstance(element.get('text'), str):
                raise ChunkingError('invalid_structure')
            if element['elementId'] in element_ids:
                raise ChunkingError('invalid_structure')
            element_ids.add(element['elementId'])
            total_characters += len(element['text'])
            if total_characters > MAX_TEXT_CHARS:
                raise ChunkingError('input_limit')
            if element.get('parentId') is not None and not valid_ref(element['parentId']):
                raise ChunkingError('invalid_structure')
            for field in ('childrenIds', 'captionIds'):
                values = element.get(field)
                if values is not None and (not isinstance(values, list) or len(values) > 1000 or any(not valid_ref(value) for value in values)):
                    raise ChunkingError('invalid_structure')
            provenance = element.get('provenance')
            if not isinstance(provenance, list) or not 1 <= len(provenance) <= 1000:
                raise ChunkingError('invalid_structure')
            for prov in provenance:
                if not isinstance(prov, dict) or type(prov.get('pageNumber')) is not int or prov['pageNumber'] != page['pageNumber']:
                    raise ChunkingError('invalid_structure')
                bbox = prov.get('bbox')
                if bbox is not None and (not isinstance(bbox, dict) or any(type(bbox.get(k)) not in (int, float) or not math.isfinite(bbox[k]) for k in ('l', 't', 'r', 'b'))):
                    raise ChunkingError('invalid_structure')
                span = prov.get('charspan')
                if span is not None and (not isinstance(span, list) or len(span) != 2 or any(type(i) is not int for i in span) or not 0 <= span[0] <= span[1]):
                    raise ChunkingError('invalid_structure')


def chunk_document(pages, vectors_payload=None):
    validate_pages(pages)
    elements = [element for page in pages for element in page['elements']]
    if len(elements) > MAX_ELEMENTS or sum(len(e['text']) for e in elements) > MAX_TEXT_CHARS:
        raise ChunkingError('input_limit')
    ids = [e.get('elementId') for e in elements]
    if any(not isinstance(value, str) or not value for value in ids) or len(set(ids)) != len(ids):
        raise ChunkingError('invalid_structure')
    units = semantic_units(pages)
    vectors = validate_vectors(vectors_payload, pages, units) if vectors_payload is not None else None
    grouped = {}
    if vectors is not None:
        for unit, vector in zip(units, vectors):
            grouped.setdefault(unit['elementId'], []).append((unit, vector))
    by_id = {e['elementId']: e for e in elements}
    chunks, protected = [], []
    for page in pages:
        number = page['pageNumber']
        for element in page['elements']:
            text, element_id = element['text'], element['elementId']
            if element['kind'] not in BODY_KINDS:
                protected.append({'pageNumber': number, 'element': element,
                                  'reason': 'protected_kind' if element['kind'] in PROTECTED_KINDS else 'structural_context' if element['kind'] in STRUCTURAL_KINDS else 'unknown_kind',
                                  'oversized': estimated_tokens(text) > MAX_TOKENS,
                                  'reviewRequired': bool(page.get('needsReview') or page.get('needsOCR'))})
                continue
            boundaries = [0]
            values = grouped.get(element_id, [])
            for (previous, left), (current, right) in zip(values, values[1:]):
                distance = 1 - max(-1.0, min(1.0, sum(a * b for a, b in zip(left, right))))
                if distance >= SEMANTIC_THRESHOLD:
                    boundaries.append(current['start'])
            boundaries.append(len(text))
            heading_refs = []
            parent, visited = element_id, set()
            while parent in by_id and parent not in visited:
                visited.add(parent)
                if by_id[parent]['kind'] in ('section_header', 'title'):
                    heading_refs.append(parent)
                parent = by_id[parent].get('parentId')
            for region, (begin, end) in enumerate(zip(boundaries, boundaries[1:])):
                for start, stop in split_ranges(text, begin, end):
                    chunk_text = text[start:stop]
                    chunks.append({'chunkId': digest(f'{number}:{element_id}:{start}:{stop}:{digest(chunk_text)}'),
                                   'pageNumber': number, 'elementId': element_id, 'kind': element['kind'],
                                   'text': chunk_text, 'start': start, 'end': stop, 'offsetUnit': 'unicode_codepoint',
                                   'estimatedTokens': estimated_tokens(chunk_text), 'semanticRegion': region,
                                   'reviewRequired': bool(page.get('needsReview') or page.get('needsOCR')),
                                   'headingRefs': heading_refs, 'headingState': 'explicit' if heading_refs else 'unknown',
                                   'provenanceScope': 'element',
                                   'contextRefs': [{**ref, 'resolved': ref['elementId'] in by_id} for ref in relationships(element)], 'provenance': element['provenance']})
                    if len(chunks) > MAX_UNITS:
                        raise ChunkingError('chunk_limit')
    return {'schemaVersion': 1, 'strategy': 'structure-semantic-recursive-v1',
            'maxEstimatedTokens': MAX_TOKENS, 'maxOverlapEstimatedTokens': OVERLAP_TOKENS,
            'semanticApplied': vectors is not None and bool(units),
            'semanticFallbackReason': ('no_vectors' if vectors is None else 'not_needed' if not units else None),
            'semanticDistanceThreshold': SEMANTIC_THRESHOLD,
            'semanticModel': vectors_payload['model'] if vectors_payload is not None else None,
            'textSha256': text_binding(pages), 'semanticUnits': units,
            'pageStates': [{'pageNumber': p['pageNumber'], 'needsReview': p.get('needsReview', False), 'needsOCR': p.get('needsOCR', False)} for p in pages],
            'reviewRequired': any(p.get('needsReview') or p.get('needsOCR') for p in pages),
            'chunks': chunks, 'protectedElements': protected,
            'integration': 'local_only_not_worker_ingest'}
