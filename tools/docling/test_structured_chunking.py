import copy
import hashlib
import json
import unittest
from unittest.mock import patch
import structured_chunking as chunker


def element(text, kind='text', identity='e1', **kwargs):
    return {'elementId': identity, 'kind': kind, 'text': text, 'provenance': [{'pageNumber': 1, 'bbox': {'l': 0, 't': 0, 'r': 1, 'b': 1}}],
            'parentId': None, 'childrenIds': None, 'captionIds': None, **kwargs}


def pages(*elements):
    return [{'pageNumber': 1, 'elements': list(elements), 'needsReview': False, 'needsOCR': False}]


def vector_payload(source, vectors):
    units = chunker.semantic_units(source)
    return {'schemaVersion': 1, 'textSha256': chunker.text_binding(source), 'dimension': 2, 'model': 'synthetic-local-model',
            'units': [{**unit, 'vector': vector} for unit, vector in zip(units, vectors)]}


class ChunkingTests(unittest.TestCase):
    def test_hard_limit_overlap_and_original_offsets_are_lossless(self):
        original = '条件を確認して使う。' * 200
        result = chunker.chunk_document(pages(element(original)))
        chunks = result['chunks']
        self.assertGreater(len(chunks), 2)
        self.assertEqual(chunks[0]['start'], 0)
        self.assertEqual(chunks[-1]['end'], len(original))
        covered = set()
        for chunk in chunks:
            self.assertEqual(chunk['text'], original[chunk['start']:chunk['end']])
            self.assertLessEqual(chunk['estimatedTokens'], 400)
            covered.update(range(chunk['start'], chunk['end']))
        self.assertEqual(len(covered), len(original))
        for left, right in zip(chunks, chunks[1:]):
            self.assertLess(right['start'], left['end'])
            self.assertLessEqual(chunker.estimated_tokens(original[right['start']:left['end']]), 65)
        self.assertFalse(result['semanticApplied'])
        self.assertEqual(result['semanticFallbackReason'], 'no_vectors')

    def test_unicode_without_spaces_is_bounded(self):
        original = '😀漢a ' * 700
        chunks = chunker.chunk_document(pages(element(original)))['chunks']
        self.assertTrue(all(c['text'] == original[c['start']:c['end']] and c['estimatedTokens'] <= 400 for c in chunks))
        self.assertEqual(chunks[-1]['end'], len(original))

    def test_structure_and_page_boundaries_are_never_merged(self):
        source = pages(element('first', identity='a'), element('second', identity='b'))
        third = element('third', identity='c'); third['provenance'][0]['pageNumber'] = 2
        source.append({'pageNumber': 2, 'elements': [third], 'needsReview': False, 'needsOCR': False})
        result = chunker.chunk_document(source)
        self.assertEqual([(c['pageNumber'], c['elementId'], c['text']) for c in result['chunks']], [(1, 'a', 'first'), (1, 'b', 'second'), (2, 'c', 'third')])

    def test_table_picture_formula_unknown_are_unchanged_and_oversized_flagged(self):
        for kind in ['table', 'picture', 'formula', 'unknown']:
            original = element('あ' * 1000, kind)
            result = chunker.chunk_document(pages(original))
            self.assertEqual(result['chunks'], [])
            self.assertEqual(result['protectedElements'][0]['element'], original)
            self.assertTrue(result['protectedElements'][0]['oversized'])

    def test_semantic_vectors_split_adjacent_topic_change_before_size_split(self):
        source = pages(element(('alpha sentence. ' * 25) + ('beta sentence. ' * 25)))
        units = chunker.semantic_units(source)
        vectors = [[1, 0] if index < 25 else [0, 1] for index in range(len(units))]
        result = chunker.chunk_document(source, vector_payload(source, vectors))
        self.assertTrue(result['semanticApplied'])
        regions = {c['semanticRegion'] for c in result['chunks']}
        self.assertEqual(regions, {0, 1})
        self.assertTrue(all(not ('alpha' in c['text'] and 'beta' in c['text']) for c in result['chunks']))

    def test_similar_vectors_do_not_split_every_sentence(self):
        source = pages(element('Same sentence. ' * 70))
        units = chunker.semantic_units(source)
        result = chunker.chunk_document(source, vector_payload(source, [[1, 0]] * len(units)))
        self.assertEqual({c['semanticRegion'] for c in result['chunks']}, {0})

    def test_tampered_missing_or_malformed_vectors_rejected(self):
        source = pages(element('Sentence. ' * 70))
        good = vector_payload(source, [[1, 0]] * len(chunker.semantic_units(source)))
        cases = []
        for field, value in [('textSha256', '0' * 64), ('dimension', 0), ('dimension', 4097), ('model', ''), ('model', None), ('units', [])]:
            changed = copy.deepcopy(good); changed[field] = value; cases.append(changed)
        for field, value in [('sha256', '0' * 64), ('start', 1), ('elementId', 'other'), ('vector', [0, 0]), ('vector', [float('nan'), 1]), ('vector', [True, 1]), ('vector', [1])]:
            changed = copy.deepcopy(good); changed['units'][0][field] = value; cases.append(changed)
        for payload in cases:
            with self.assertRaises(chunker.ChunkingError):
                chunker.chunk_document(source, payload)

    def test_explicit_heading_and_caption_links_only(self):
        header = element('Heading', 'section_header', 'h', level=2)
        body = element('body', identity='b', parentId='h', captionIds=['caption'])
        result = chunker.chunk_document(pages(header, body))
        self.assertEqual(result['chunks'][0]['headingRefs'], ['h'])
        self.assertIn({'role': 'caption', 'elementId': 'caption', 'resolved': False}, result['chunks'][0]['contextRefs'])
        body['parentId'] = None
        result = chunker.chunk_document(pages(header, body))
        self.assertEqual(result['chunks'][0]['headingRefs'], [])
        self.assertEqual(result['chunks'][0]['headingState'], 'unknown')

    def test_limits_fail_closed(self):
        with patch.object(chunker, 'MAX_UNITS', 1):
            with self.assertRaises(chunker.ChunkingError):
                chunker.chunk_document(pages(element('Sentence. ' * 70)))
        with patch.object(chunker, 'MAX_TEXT_CHARS', 1):
            with self.assertRaises(chunker.ChunkingError):
                chunker.chunk_document(pages(element('too long')))
        with self.assertRaises(chunker.ChunkingError):
            chunker.chunk_document(pages(element('x'), element('duplicate')))

    def test_unit_manifest_supplies_exact_text_hashes_and_offsets(self):
        from semantic_manifest import manifest_for_pages
        source = pages(element('Original sentence. ' * 40))
        manifest = manifest_for_pages(source)
        self.assertTrue(manifest['units'])
        for unit in manifest['units']:
            self.assertEqual(unit['text'], source[0]['elements'][0]['text'][unit['start']:unit['end']])
            self.assertEqual(hashlib.sha256(unit['text'].encode()).hexdigest(), unit['sha256'])
            unit['vector'] = [1, 0]
        manifest['dimension'] = 2
        manifest['model'] = 'synthetic-offline-encoder'
        result = chunker.chunk_document(source, manifest)
        self.assertTrue(result['semanticApplied'])
        self.assertEqual(result['semanticModel'], 'synthetic-offline-encoder')

    def test_bad_structure_relations_and_physical_pages_are_rejected(self):
        for source in [pages(element('x', parentId=[])), pages(element('x', captionIds='bad')),
                       [{'pageNumber': True, 'elements': []}], [{'pageNumber': 1, 'elements': []}, {'pageNumber': 1, 'elements': []}]]:
            with self.assertRaises(chunker.ChunkingError):
                chunker.chunk_document(source)

    def test_semantic_manifest_rejects_duplicate_ids_and_global_limits(self):
        from semantic_manifest import manifest_for_pages
        with self.assertRaises(chunker.ChunkingError):
            manifest_for_pages(pages(element('first'), element('duplicate')))
        with patch.object(chunker, 'MAX_ELEMENTS', 1):
            with self.assertRaises(chunker.ChunkingError):
                manifest_for_pages(pages(element('a', identity='a'), element('b', identity='b')))
        with patch.object(chunker, 'MAX_TEXT_CHARS', 1):
            with self.assertRaises(chunker.ChunkingError):
                manifest_for_pages(pages(element('too long')))

    def test_review_state_follows_chunks_and_protected_elements(self):
        source = pages(element('body'), element('table', 'table', 't'))
        source[0]['needsReview'] = True
        result = chunker.chunk_document(source)
        self.assertTrue(result['reviewRequired'])
        self.assertTrue(result['chunks'][0]['reviewRequired'])
        self.assertTrue(result['protectedElements'][0]['reviewRequired'])
        self.assertTrue(result['pageStates'][0]['needsReview'])

    def test_missing_page_review_flags_never_means_safe(self):
        source = pages(element('body'))
        for flag in ('needsReview', 'needsOCR'):
            bad = copy.deepcopy(source)
            del bad[0][flag]
            with self.assertRaises(chunker.ChunkingError):
                chunker.chunk_document(bad)

    def test_original_input_not_mutated(self):
        source = pages(element('Sentence. ' * 70))
        snapshot = copy.deepcopy(source)
        chunker.chunk_document(source)
        self.assertEqual(source, snapshot)
