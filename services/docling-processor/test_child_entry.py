"""Fixed entry integration contract without invoking Docling or changing test process limits."""
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

import child_entry


class ChildEntryTests(unittest.TestCase):
    def test_fixed_extract_signature_limits_and_private_result(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); artifacts = root / 'artifacts'; artifacts.mkdir()
            calls = []
            def extract(input_path, artifacts_path, output_path, *, chunks_output):
                calls.append((input_path, artifacts_path, output_path, chunks_output))
                self.assertTrue(all(isinstance(v, str) for v in calls[0]))
                Path(output_path).write_text('{}'); Path(chunks_output).write_text('{}')
            def private_outputs(values):
                for path, content in values:
                    fd = os.open(path, os.O_EXCL | os.O_CREAT | os.O_WRONLY, 0o600)
                    with os.fdopen(fd, 'wb') as stream: stream.write(content)
            module = types.SimpleNamespace(extract=extract, private_outputs=private_outputs)
            packaging = types.SimpleNamespace(prepare_batches=lambda structured, chunks: {'version': 1, 'integration': 'prepared_only_no_upload', 'batches': []})
            old_umask = os.umask(0o077)
            try:
                with patch.dict(sys.modules, {'extract_pdf': module, 'index_payload': packaging}), patch.object(sys, 'argv', ['child_entry.py', str(root), str(artifacts)]), patch.object(child_entry.resource, 'setrlimit') as limits:
                    self.assertEqual(child_entry.main(), 0)
                self.assertEqual(module.MAX_PAGES, 20)
                self.assertEqual(module.MAX_PDF_BYTES, 10 * 1024 * 1024)
                self.assertEqual(module.MAX_OUTPUT_BYTES, 16 * 1024 * 1024)
                self.assertEqual(len(limits.call_args_list), 3)
                self.assertEqual(calls[0][0], str(root / 'input.pdf'))
                self.assertEqual(calls[0][1], str(artifacts))
                self.assertEqual((root / 'prepared.json').stat().st_mode & 0o777, 0o600)
                self.assertEqual(json.loads((root / 'prepared.json').read_bytes())['version'], 1)
            finally:
                os.umask(old_umask)

    def test_oversized_packaging_has_no_response_file(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            def extract(input_path, artifacts_path, output_path, *, chunks_output):
                Path(output_path).write_text('{}'); Path(chunks_output).write_text('{}')
            module = types.SimpleNamespace(extract=extract, private_outputs=lambda _: self.fail('must not write oversized output'))
            packaging = types.SimpleNamespace(prepare_batches=lambda *_: {'large': 'x' * (4 * 1024 * 1024)})
            old_umask = os.umask(0o077)
            try:
                with patch.dict(sys.modules, {'extract_pdf': module, 'index_payload': packaging}), patch.object(sys, 'argv', ['child_entry.py', str(root), str(root)]), patch.object(child_entry.resource, 'setrlimit'):
                    self.assertEqual(child_entry.main(), 1)
                    self.assertFalse((root / 'prepared.json').exists())
            finally:
                os.umask(old_umask)


if __name__ == '__main__':
    unittest.main()
