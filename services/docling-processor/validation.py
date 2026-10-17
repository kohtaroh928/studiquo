"""Defensive validation of a fixed child's prepared manifest. No parser imports."""
import hashlib
import json
import math
import re


def _fail():
    raise ValueError('invalid_manifest')


def _object(value, keys, optional=()):
    if type(value) is not dict or not set(keys) <= value.keys() or not value.keys() <= set(keys) | set(optional):
        _fail()
    return value


def _int(value, low, high):
    if type(value) is not int or not low <= value <= high:
        _fail()
    return value


def _number(value, low, high):
    if type(value) not in (int, float) or not math.isfinite(value) or not low <= value <= high:
        _fail()


def _string(value, low, high):
    if type(value) is not str or not low <= len(value.encode('utf-16-le')) // 2 <= high:
        _fail()
    return value


def _hex(value):
    if type(value) is not str or not re.fullmatch('[a-f0-9]{64}', value):
        _fail()
    return value


def _ref(value):
    if not re.fullmatch(r'[A-Za-z0-9_/#:.\-]+', _string(value, 1, 512)):
        _fail()


def _array(value, low, high):
    if type(value) is not list or not low <= len(value) <= high:
        _fail()
    return value


def _choice(value, options):
    if type(value) is not str or value not in options:
        _fail()


def _canonical(value):
    return json.dumps(value, ensure_ascii=False, allow_nan=False, sort_keys=True, separators=(',', ':')).encode('utf-8')


def _pairs(values):
    result = {}
    for key, value in values:
        if key in result:
            _fail()
        result[key] = value
    return result


def _document(d):
    _object(d, ['parser', 'pdfSha256', 'strategy', 'semanticApplied', 'semanticModel', 'maxEstimatedTokens', 'maxOverlapEstimatedTokens', 'semanticDistanceThreshold', 'semanticFallbackReason', 'namespaceScope', 'offsetUnit', 'provenanceScope'])
    parser = _object(d['parser'], ['name', 'version', 'profile'])
    if parser != {'name': 'docling', 'version': '2.139.0', 'profile': 'native-layout-table-v1'}:
        _fail()
    _hex(d['pdfSha256'])
    if (d['strategy'] != 'structure-semantic-recursive-v1' or d['namespaceScope'] != 'document_parser_only_not_authentication'
            or d['offsetUnit'] != 'unicode_codepoint' or d['provenanceScope'] != 'element' or type(d['semanticApplied']) is not bool):
        _fail()
    if d['semanticApplied'] is not False or d['semanticModel'] is not None or d['semanticFallbackReason'] != 'no_vectors':
        _fail()
    if d['semanticModel'] is not None:
        if not _string(d['semanticModel'], 1, 128).strip():
            _fail()
    if d['semanticApplied']:
        if d['semanticModel'] is None or d['semanticFallbackReason'] is not None:
            _fail()
    elif d['semanticFallbackReason'] not in ('no_vectors', 'not_needed'):
        _fail()
    if _int(d['maxOverlapEstimatedTokens'], 0, 65) >= _int(d['maxEstimatedTokens'], 1, 400):
        _fail()
    _number(d['semanticDistanceThreshold'], 0, 2)


def _record(m, body, number, namespace):
    _object(m, ['documentNamespace', 'kind', 'elementId', 'localId', 'idSource', 'pageNumbers', 'provenanceScope', 'provenance', 'coordinateState', 'headingPath', 'contextRefs', 'review', 'source'], ['tableStructureSha256'])
    if m['documentNamespace'] != namespace or m['pageNumbers'] != [number] or type(m['pageNumbers'][0]) is not int or m['provenanceScope'] != 'element':
        _fail()
    _choice(m['kind'], ['text', 'paragraph', 'title', 'section_header', 'list_item', 'footnote', 'caption', 'table', 'formula'])
    _choice(m['idSource'], ['docling_self_ref', 'synthetic_unknown', 'unknown'])
    _ref(m['elementId']); _ref(m['localId'])
    known = True
    for p in _array(m['provenance'], 1, 16):
        _object(p, ['pageNumber', 'bbox'], ['charspan'])
        if _int(p['pageNumber'], 1, 20) != number:
            _fail()
        if p['bbox'] is None:
            known = False
        else:
            box = _object(p['bbox'], ['l', 't', 'r', 'b'], ['coordOrigin'])
            for key in ('l', 't', 'r', 'b'):
                _number(box[key], -1e9, 1e9)
            if 'coordOrigin' in box:
                _string(box['coordOrigin'], 0, 128)
            known &= box.get('coordOrigin') in ('TOPLEFT', 'BOTTOMLEFT')
        if p.get('charspan') is not None:
            span = _array(p['charspan'], 2, 2)
            if _int(span[0], 0, 8000000) > _int(span[1], 0, 8000000):
                _fail()
    if m['coordinateState'] != ('known' if known else 'unknown'):
        _fail()
    h = _object(m['headingPath'], ['state', 'reason', 'items'])
    _choice(h['state'], ['explicit', 'partial', 'unknown'])
    _choice(h['reason'], ['complete', 'cycle', 'missing_parent', 'ancestry_limit', 'no_explicit_heading'])
    headings = []
    for item in _array(h['items'], 0, 16):
        _object(item, ['elementId', 'text', 'level']); _ref(item['elementId'])
        headings.append(_string(item['text'], 0, 300))
        if item['level'] is not None:
            _int(item['level'], 1, 100)
    _string(' / '.join(headings), 0, 1000)
    if (h['state'] == 'unknown' and headings or h['state'] == 'explicit' and (not headings or h['reason'] != 'complete')
            or h['state'] == 'partial' and (not headings or h['reason'] == 'complete')):
        _fail()
    for ref in _array(m['contextRefs'], 0, 32):
        _object(ref, ['role', 'elementId', 'resolved']); _ref(ref['elementId'])
        _choice(ref['role'], ['parent', 'child', 'caption'])
        if type(ref['resolved']) is not bool:
            _fail()
    review = _object(m['review'], ['needsReview', 'needsOCR', 'reviewRequired', 'oversized'])
    if any(value is not False for value in review.values()):
        _fail()
    source = _object(m['source'], ['start', 'end', 'offsetUnit', 'textSha256'])
    if (_int(source['end'], 0, 8000000) - _int(source['start'], 0, 8000000) != len(body)
            or not body or source['offsetUnit'] != 'unicode_codepoint'
            or _hex(source['textSha256']) != hashlib.sha256(body.encode('utf-8')).hexdigest()):
        _fail()
    if 'tableStructureSha256' in m:
        _hex(m['tableStructureSha256'])
    if len(_canonical(m)) > 16384:
        _fail()


def _bounded_json_shape(raw):
    # Byte-level preflight avoids handing unbounded depth/node work to the decoder.
    depth, separators, quoted, escaped = 0, 0, False, False
    for byte in raw:
        if quoted:
            if escaped:
                escaped = False
            elif byte == 92:
                escaped = True
            elif byte == 34:
                quoted = False
            continue
        if byte == 34:
            quoted = True
        elif byte in (91, 123):
            depth += 1
            separators += 1
            if depth > 64:
                _fail()
        elif byte in (93, 125):
            depth -= 1
            if depth < 0:
                _fail()
        elif byte in (44, 58):
            separators += 1
        if separators > 200000:
            _fail()
    if quoted or depth:
        _fail()


def validate_manifest(raw, pdf_digest):
    """Reject partial, extra-key, nonfinite or PDF-mismatched output before returning bytes."""
    _bounded_json_shape(raw)
    value = json.loads(raw, object_pairs_hook=_pairs, parse_constant=lambda _: _fail())
    _object(value, ['version', 'integration', 'batches'])
    if _int(value['version'], 1, 1) != 1 or value['integration'] != 'prepared_only_no_upload':
        _fail()
    all_pages, total, common, identities = [], None, None, set()
    for batch in _array(value['batches'], 1, 20):
        _object(batch, ['structure', 'totalPages', 'pages'])
        if len(_canonical(batch)) > 240 * 1024:
            _fail()
        structure = _object(batch['structure'], ['version', 'document', 'documentNamespace'])
        _int(structure['version'], 1, 1); _document(structure['document'])
        document = structure['document']
        namespace = _hex(structure['documentNamespace'])
        if document['pdfSha256'] != pdf_digest or namespace != hashlib.sha256(_canonical({'parser': document['parser'], 'pdfSha256': pdf_digest})).hexdigest():
            _fail()
        if common is not None and common != structure:
            _fail()
        common = structure
        count = _int(batch['totalPages'], 1, 20)
        if total is not None and total != count:
            _fail()
        total = count
        for page in _array(batch['pages'], 1, 5):
            _object(page, ['pageNumber', 'text', 'structured'])
            number = _int(page['pageNumber'], 1, total)
            if number != len(all_pages) + 1:
                _fail()
            all_pages.append(number)
            text = _string(page['text'], 1, 100000)
            structured = _object(page['structured'], ['version', 'records'])
            _int(structured['version'], 1, 1)
            for row in _array(structured['records'], 1, 100):
                _object(row, ['text', 'metadata'])
                body = _string(row['text'], 1, 6000)
                if not body.strip() or body not in text:
                    _fail()
                m = row['metadata']; _record(m, body, number, namespace)
                if m['localId'] in identities:
                    _fail()
                identities.add(m['localId'])
                if len(_canonical({'version': 1, 'documentNamespace': namespace, 'document': document, 'record': m})) > 16384:
                    _fail()
    if all_pages != list(range(1, total + 1)):
        _fail()
    return total
