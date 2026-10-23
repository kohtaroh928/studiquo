import copy
import unittest
from unittest.mock import patch
import metadata as meta
from structured_chunking import chunk_document
from test_structured_chunking import element, pages


def fixture(source=None, unassigned=None):
    source = source or pages(element('合成の本文です。😀', idSource='docling_self_ref'))
    envelope = chunk_document(source)
    envelope.update(parser={'name': 'docling', 'version': '2.139.0', 'profile': 'native-layout-table-v1'},
                    pdfSha256='a' * 64, unassignedElements=unassigned or [])
    envelope['reviewRequired'] |= bool(unassigned)
    return source, envelope


class MetadataTests(unittest.TestCase):
    def test_preserves_original_fields_and_input(self):
        source, envelope = fixture()
        before = copy.deepcopy((source, envelope))
        out = meta.add_metadata(envelope, source)
        self.assertEqual((source, envelope), before)
        for key in envelope:
            if key != 'chunks':
                self.assertEqual(out[key], envelope[key])
        for key, value in envelope['chunks'][0].items():
            self.assertEqual(out['chunks'][0][key], value)
        self.assertTrue(meta.verify_metadata(out))
        data = out['chunks'][0]['metadata']
        self.assertEqual(data['source']['end'], len('合成の本文です。😀'))
        self.assertEqual(data['provenanceScope'], 'element')
        self.assertEqual(data['coordinateState'], 'unknown')

    def test_metadata_changes_without_text_or_chunk_id_changes(self):
        source, env = fixture()
        first = meta.add_metadata(env, source)
        changed = copy.deepcopy(source)
        changed[0]['elements'][0]['provenance'][0]['bbox']['l'] = 0.5
        _, second_env = fixture(changed)
        second = meta.add_metadata(second_env, changed)
        self.assertEqual(first['textSha256'], second['textSha256'])
        self.assertEqual(first['chunks'][0]['chunkId'], second['chunks'][0]['chunkId'])
        self.assertNotEqual(first['metadataSha256'], second['metadataSha256'])
        changed[0]['needsReview'] = True
        _, third_env = fixture(changed)
        third = meta.add_metadata(third_env, changed)
        self.assertNotEqual(second['metadataSha256'], third['metadataSha256'])
        self.assertTrue(third['chunks'][0]['metadata']['review']['reviewRequired'])

    def test_document_and_parser_namespace(self):
        source, env = fixture()
        first = meta.add_metadata(env, source)
        for key, value in [('pdfSha256', 'b' * 64), ('parser', {**env['parser'], 'version': 'different'})]:
            changed = copy.deepcopy(env); changed[key] = value
            second = meta.add_metadata(changed, source)
            self.assertNotEqual(first['documentNamespace'], second['documentNamespace'])
            self.assertEqual(first['chunks'][0]['chunkId'], second['chunks'][0]['chunkId'])

    def test_explicit_heading_path_and_unresolved_cycle(self):
        source = pages(element('見出し', 'section_header', 'h', level=1),
                       element('本文', identity='b', parentId='h', captionIds=['missing']))
        _, env = fixture(source)
        out = meta.add_metadata(env, source)
        data = out['chunks'][0]['metadata']
        self.assertEqual(data['headingPath']['items'][0]['elementId'], 'h')
        self.assertEqual(data['headingPath']['state'], 'explicit')
        self.assertFalse(data['contextRefs'][-1]['resolved'])
        source[0]['elements'][0]['parentId'] = 'b'
        _, env = fixture(source)
        data = meta.add_metadata(env, source)['chunks'][0]['metadata']
        self.assertEqual(data['headingPath']['reason'], 'cycle')
        self.assertEqual(data['headingPath']['state'], 'partial')

    def test_unassigned_multiple_pages_and_blank_pages_survive(self):
        source = pages(element('本文'))
        source.append({'pageNumber': 2, 'elements': [], 'needsReview': True, 'needsOCR': True})
        item = element('複数ページの表', 'table', 't')
        item['provenance'].append({**copy.deepcopy(item['provenance'][0]), 'pageNumber': 2})
        _, env = fixture(source, [item])
        out = meta.add_metadata(env, source)
        self.assertEqual(out['unassignedElements'][0]['metadata']['pageNumbers'], [1, 2])
        self.assertTrue(out['unassignedElements'][0]['metadata']['review']['reviewRequired'])
        self.assertTrue(out['pageStates'][1]['needsOCR'])
        item['provenance'] = []
        _, env = fixture(source, [item])
        self.assertEqual(meta.add_metadata(env, source)['unassignedElements'][0]['metadata']['pageNumbers'], [])

    def test_table_structure_changes_hash(self):
        source = pages(element('表', 'table', 't', table={'cells': ['synthetic']}))
        _, env = fixture(source)
        first = meta.add_metadata(env, source)
        source[0]['elements'][0]['table']['cells'][0] = 'changed'
        _, env = fixture(source)
        second = meta.add_metadata(env, source)
        self.assertNotEqual(first['metadataSha256'], second['metadataSha256'])

    def test_digest_detects_modification(self):
        source, env = fixture()
        out = meta.add_metadata(env, source)
        out['chunks'][0]['metadata']['kind'] = 'table'
        self.assertFalse(meta.verify_metadata(out))
        self.assertFalse(meta.verify_metadata(None))

    def test_cumulative_metadata_budget_stops_amplification(self):
        source = pages(element('あ' * 5000))
        _, env = fixture(source)
        self.assertGreater(len(env['chunks']), 2)
        first = meta.add_metadata(env, source)
        per_record = len(meta.bounded_json(first['chunks'][0]['metadata']))
        with patch.object(meta, 'MAX_METADATA_BYTES', per_record * 2):
            with self.assertRaises(meta.MetadataError): meta.add_metadata(env, source)
        self.assertFalse(meta.verify_metadata({'x': 10 ** 400}))

    def test_invalid_inputs_and_resource_limits(self):
        source, env = fixture()
        for mutate in [lambda e: e.update(pdfSha256='bad'),
                       lambda e: e['chunks'][0].update(start=True),
                       lambda e: e['chunks'][0].update(text='wrong'),
                       lambda e: e['pageStates'][0].update(needsOCR=True)]:
            bad = copy.deepcopy(env); mutate(bad)
            with self.assertRaises(meta.MetadataError): meta.add_metadata(bad, source)
        with patch.object(meta, 'MAX_RECORDS', 0):
            with self.assertRaises(meta.MetadataError): meta.add_metadata(env, source)
        with patch.object(meta, 'MAX_METADATA_BYTES', 32):
            with self.assertRaises(meta.MetadataError): meta.add_metadata(env, source)


if __name__ == '__main__':
    unittest.main()
