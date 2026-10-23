import copy
import unittest
from index_payload import prepare_batches, worker_token_count
from metadata import add_metadata, MetadataError
from test_metadata import fixture
from test_structured_chunking import element, pages


def prepared(source=None):
    source, env = fixture(source)
    for page in source:
        page['text'] = '\n\n'.join(e['text'] for e in page['elements'])
    structured = {'schemaVersion': 1, 'parser': env['parser'], 'pdfSha256': env['pdfSha256'],
                  'totalPages': len(source), 'pages': source, 'unassignedElements': []}
    return structured, add_metadata(env, source)


class IndexPayloadTests(unittest.TestCase):
    def test_original_text_and_metadata_preserved(self):
        structured, chunks = prepared()
        snapshot = copy.deepcopy((structured, chunks))
        result = prepare_batches(structured, chunks)
        self.assertEqual((structured, chunks), snapshot)
        row = result['batches'][0]['pages'][0]['structured']['records'][0]
        self.assertEqual(row['text'], chunks['chunks'][0]['text'])
        self.assertEqual(row['metadata'], chunks['chunks'][0]['metadata'])
        self.assertNotIn('sourceHash', result['batches'][0])
        self.assertEqual(result['integration'], 'prepared_only_no_upload')

    def test_long_body_and_all_protected_rows_in_original_order(self):
        source = pages(element('あ' * 1000, identity='b'), element('見出し', 'section_header', 'h'),
                       element('|a|b|', 'table', 't', table={'cells': []}))
        structured, chunks = prepared(source)
        result = prepare_batches(structured, chunks)
        rows = result['batches'][0]['pages'][0]['structured']['records']
        self.assertEqual([r['metadata']['kind'] for r in rows][-2:], ['section_header', 'table'])
        self.assertEqual(len(rows), len(chunks['chunks']) + len(chunks['protectedElements']))
        self.assertIn('tableStructureSha256', rows[-1]['metadata'])
        self.assertNotIn('table', rows[-1])

    def test_100_pages_batched_without_missing_pages(self):
        source = []
        for i in range(1, 101):
            e = element('Synthetic page.', identity=f'e{i}')
            e['provenance'][0]['pageNumber'] = i
            source.append({'pageNumber': i, 'elements': [e], 'needsReview': False, 'needsOCR': False})
        structured, chunks = prepared(source)
        result = prepare_batches(structured, chunks)
        self.assertEqual(len(result['batches']), 20)
        self.assertEqual([p['pageNumber'] for b in result['batches'] for p in b['pages']], list(range(1, 101)))

    def test_partial_or_unsafe_document_is_rejected(self):
        for kind in ['picture', 'unknown']:
            structured, chunks = prepared(pages(element('synthetic', kind)))
            with self.assertRaises(MetadataError): prepare_batches(structured, chunks)
        structured, chunks = prepared()
        chunks['chunks'][0]['text'] = 'tampered'
        with self.assertRaises(MetadataError): prepare_batches(structured, chunks)
        structured, chunks = prepared()
        structured['pages'][0]['needsReview'] = True
        with self.assertRaises(MetadataError): prepare_batches(structured, chunks)
        structured, chunks = prepared()
        chunks['unassignedElements'] = [element('orphan')]
        with self.assertRaises(MetadataError): prepare_batches(structured, chunks)

    def test_worker_token_and_heading_join_bounds(self):
        self.assertEqual(worker_token_count('! ' * 501), 501)
        self.assertEqual(worker_token_count('漢字 abc 😀'), 4)
        self.assertEqual(worker_token_count('\ufeffa\ufeff'), 1)
        structured, chunks = prepared(pages(element('! ' * 501)))
        with self.assertRaises(MetadataError): prepare_batches(structured, chunks)
        headings = [element('h' * 250, 'section_header', f'h{i}', parentId=f'h{i-1}' if i else None) for i in range(4)]
        structured, chunks = prepared(pages(*headings, element('body', identity='b', parentId='h3')))
        with self.assertRaises(MetadataError): prepare_batches(structured, chunks)

    def test_missing_body_coverage_is_rejected_even_with_new_digest(self):
        source = pages(element('あ' * 1500))
        structured, chunks = prepared(source)
        chunks['chunks'] = chunks['chunks'][1:]
        chunks = add_metadata(chunks, structured['pages'])
        with self.assertRaises(MetadataError): prepare_batches(structured, chunks)


if __name__ == '__main__': unittest.main()
