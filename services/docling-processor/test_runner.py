"""Synthetic-only subprocess tests. No models, sockets, secrets or PDF contents logged."""
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

import runner
from runner import PDFProcessor, ProcessorError
from validation import validate_manifest

PDF = b'%PDF-1.7\nSynthetic processor contract only'


def manifest(pages=1):
    pdf_hash = hashlib.sha256(PDF).hexdigest()
    parser = {'name': 'docling', 'version': '2.139.0', 'profile': 'native-layout-table-v1'}
    canonical = lambda v: json.dumps(v, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode()
    namespace = hashlib.sha256(canonical({'parser': parser, 'pdfSha256': pdf_hash})).hexdigest()
    document = {'parser': parser, 'pdfSha256': pdf_hash, 'strategy': 'structure-semantic-recursive-v1', 'semanticApplied': False,
                'semanticModel': None, 'maxEstimatedTokens': 400, 'maxOverlapEstimatedTokens': 65, 'semanticDistanceThreshold': .35,
                'semanticFallbackReason': 'no_vectors', 'namespaceScope': 'document_parser_only_not_authentication',
                'offsetUnit': 'unicode_codepoint', 'provenanceScope': 'element'}
    structure = {'version': 1, 'documentNamespace': namespace, 'document': document}
    output = []
    for i in range(1, pages + 1):
        body = 'Synthetic paragraph.'
        metadata = {'documentNamespace': namespace, 'kind': 'text', 'elementId': f'#/texts/{i}', 'localId': f'body:{i}',
                    'idSource': 'docling_self_ref', 'pageNumbers': [i], 'provenanceScope': 'element',
                    'provenance': [{'pageNumber': i, 'bbox': None, 'charspan': [0, len(body)]}], 'coordinateState': 'unknown',
                    'headingPath': {'state': 'unknown', 'reason': 'no_explicit_heading', 'items': []}, 'contextRefs': [],
                    'review': {'needsReview': False, 'needsOCR': False, 'reviewRequired': False, 'oversized': False},
                    'source': {'start': 0, 'end': len(body), 'offsetUnit': 'unicode_codepoint', 'textSha256': hashlib.sha256(body.encode()).hexdigest()}}
        output.append({'pageNumber': i, 'text': body, 'structured': {'version': 1, 'records': [{'text': body, 'metadata': metadata}]}})
    return {'version': 1, 'integration': 'prepared_only_no_upload', 'batches': [
        {'structure': structure, 'totalPages': pages, 'pages': output[start:start + 5]} for start in range(0, pages, 5)]}


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.artifacts = self.root / 'artifacts'; self.artifacts.mkdir()
        self.jobs = self.root / 'jobs'; self.jobs.mkdir()
        self.processor = PDFProcessor(python_executable=sys.executable, artifacts_directory=self.artifacts, temporary_root=self.jobs)
        self.created = []

    def tearDown(self):
        self.temp.cleanup()

    def run_child(self, *, output=None, code=None, permissions=0o600, cancel=None, deadline=1):
        payload = json.dumps(manifest()).encode() if output is None else output
        def launch(job, environment):
            self.created.append(job)
            self.assertEqual(stat.S_IMODE(job.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE((job / 'input.pdf').stat().st_mode), 0o600)
            self.assertNotIn('OPENAI_API_KEY', environment)
            self.assertEqual(environment['HF_HUB_OFFLINE'], '1')
            (job / 'prepared.json').write_bytes(payload)
            (job / 'prepared.json').chmod(permissions)
            script = code or 'import sys; print("SYNTHETIC_BODY_MARKER"); print("SYNTHETIC_BODY_MARKER",file=sys.stderr)'
            return subprocess.Popen([sys.executable, '-c', script], env=environment, cwd=job,
                                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                    start_new_session=True)
        with patch.object(self.processor, '_launch', side_effect=launch), patch.object(runner, 'DEADLINE_SECONDS', deadline):
            return self.processor.run_pdf(PDF, cancel_event=cancel)

    def assertCode(self, code, function):
        with self.assertRaises(ProcessorError) as caught:
            function()
        self.assertEqual(str(caught.exception), code)
        self.assertEqual(caught.exception.code, code)
        self.assertEqual(list(self.jobs.iterdir()), [])

    def test_success_private_modes_digest_and_cleanup(self):
        value = self.run_child()
        self.assertEqual(value.total_pages, 1)
        self.assertEqual(value.pdf_sha256, hashlib.sha256(PDF).hexdigest())
        self.assertEqual(json.loads(value.manifest), manifest())
        self.assertEqual(list(self.jobs.iterdir()), [])

    def test_input_limit_type_magic_and_no_job(self):
        for data in [b'', b'not pdf', '%PDF-text', bytearray(PDF), b'%PDF-' + b'x' * runner.MAX_PDF_BYTES]:
            self.assertCode('input_invalid', lambda: self.processor.run_pdf(data))
        self.assertCode('input_invalid', lambda: self.processor.run_pdf(PDF, cancel_event=True))

    def test_precancel_never_launches(self):
        event = threading.Event(); event.set()
        with patch.object(self.processor, '_launch') as launch:
            self.assertCode('cancelled', lambda: self.processor.run_pdf(PDF, cancel_event=event))
            launch.assert_not_called()

    def test_deadline_kills_process_and_cleans_up(self):
        start = time.monotonic()
        self.assertCode('timeout', lambda: self.run_child(code='import time; time.sleep(30)', deadline=.1))
        self.assertLess(time.monotonic() - start, 2)

    def test_cancellation_kills_process_and_cleans_up(self):
        event = threading.Event()
        timer = threading.Timer(.1, event.set); timer.start()
        try:
            self.assertCode('cancelled', lambda: self.run_child(code='import time; time.sleep(30)', cancel=event))
        finally:
            timer.cancel()

    def test_kills_descendants_on_timeout(self):
        marker = self.root / 'descendant-survived'
        grandchild = f'import time; from pathlib import Path; time.sleep(.4); Path({str(marker)!r}).write_text("survived")'
        code = f'import subprocess,sys,time; subprocess.Popen([sys.executable,"-c",{grandchild!r}]); time.sleep(30)'
        self.assertCode('timeout', lambda: self.run_child(code=code, deadline=.15))
        time.sleep(.5)
        self.assertFalse(marker.exists())

    def test_kills_descendants_even_when_leader_succeeds(self):
        marker = self.root / 'descendant-survived'
        grandchild = f'import time; from pathlib import Path; time.sleep(.3); Path({str(marker)!r}).write_text("survived")'
        code = f'import subprocess,sys; subprocess.Popen([sys.executable,"-c",{grandchild!r}])'
        self.run_child(code=code)
        time.sleep(.4)
        self.assertFalse(marker.exists())

    def test_child_failure_and_spawn_failure_have_fixed_errors(self):
        self.assertCode('conversion_failed', lambda: self.run_child(code='raise RuntimeError("SYNTHETIC_BODY_MARKER")'))
        with patch.object(self.processor, '_launch', side_effect=OSError('SYNTHETIC_BODY_MARKER')):
            self.assertCode('conversion_failed', lambda: self.processor.run_pdf(PDF))

    def test_output_size_permissions_and_invalid_json(self):
        self.assertCode('output_invalid', lambda: self.run_child(output=b'x' * (runner.MAX_RESPONSE_BYTES + 1)))
        self.assertCode('output_invalid', lambda: self.run_child(permissions=0o644))
        self.assertCode('output_invalid', lambda: self.run_child(output=b'{invalid}'))
        self.assertCode('output_invalid', lambda: self.run_child(output=b'{}'))

    def test_nested_schema_hash_pagecoverage_and_duplicatekeys(self):
        for field in ['pdf_hash', 'total_pages', 'page_number', 'unknown', 'review', 'record_hash', 'namespace', 'empty_records']:
            value = manifest()
            batch = value['batches'][0]; page = batch['pages'][0]; metadata = page['structured']['records'][0]['metadata']
            if field == 'pdf_hash': batch['structure']['document']['pdfSha256'] = '0' * 64
            elif field == 'total_pages': batch['totalPages'] = 2
            elif field == 'page_number': page['pageNumber'] = True
            elif field == 'unknown': metadata['unexpected'] = True
            elif field == 'review': metadata['review']['needsReview'] = True
            elif field == 'record_hash': metadata['source']['textSha256'] = '0' * 64
            elif field == 'namespace': batch['structure']['documentNamespace'] = '0' * 64
            elif field == 'empty_records': page['structured']['records'] = []
            self.assertCode('output_invalid', lambda: self.run_child(output=json.dumps(value).encode()))
        encoded = json.dumps(manifest()).replace('"version": 1', '"version":1,"version":1', 1).encode()
        self.assertCode('output_invalid', lambda: self.run_child(output=encoded))
        encoded = b'[' * 65 + b'0' + b']' * 65
        self.assertCode('output_invalid', lambda: self.run_child(output=encoded))
        encoded = json.dumps(manifest()).replace('0.35', 'NaN').encode()
        self.assertCode('output_invalid', lambda: self.run_child(output=encoded))

    def test_fixed_parser_and_no_vector_strategy_required(self):
        for field, replacement in [('parser', {'name': 'other', 'version': '1', 'profile': 'other'}),
                                   ('semanticApplied', True), ('semanticModel', 'unexpected'),
                                   ('semanticFallbackReason', 'not_needed')]:
            value = manifest(); value['batches'][0]['structure']['document'][field] = replacement
            self.assertCode('output_invalid', lambda: self.run_child(output=json.dumps(value).encode()))

    def test_20_pages_supported_but_21_rejected(self):
        self.assertEqual(self.run_child(output=json.dumps(manifest(20)).encode()).total_pages, 20)
        self.assertCode('output_invalid', lambda: self.run_child(output=json.dumps(manifest(21)).encode()))

    def test_cleanup_attempted_after_kill_failure_and_fixed_error(self):
        def fail_after_kill(pid, sig):
            raise PermissionError('SYNTHETIC_BODY_MARKER')
        with patch.object(runner.os, 'killpg', side_effect=fail_after_kill):
            self.assertCode('cleanup_failed', lambda: self.run_child())

    def test_cleanup_attempted_after_wait_failure_and_fixed_error(self):
        original = subprocess.Popen.wait
        def failed_second_wait(process, *args, **kwargs):
            if getattr(process, '_already_waited', False):
                raise OSError('SYNTHETIC_BODY_MARKER')
            result = original(process, *args, **kwargs); process._already_waited = True
            return result
        with patch.object(subprocess.Popen, 'wait', failed_second_wait):
            self.assertCode('cleanup_failed', lambda: self.run_child())

    def test_cleanup_failure_does_not_report_success_or_raw_path(self):
        with patch.object(runner.shutil, 'rmtree', side_effect=OSError('SYNTHETIC_BODY_MARKER')):
            with self.assertRaises(ProcessorError) as caught:
                self.run_child()
            self.assertEqual(str(caught.exception), 'cleanup_failed')
        self.assertEqual(len(list(self.jobs.iterdir())), 1)

    def test_fixed_child_arguments_and_null_logs(self):
        with patch.object(runner.subprocess, 'Popen') as spawn:
            self.processor._launch(self.root, {'HF_HUB_OFFLINE': '1'})
        args, options = spawn.call_args
        self.assertEqual(args[0], [str(Path(sys.executable).absolute()), '-I', '-B', str(runner._CHILD_ENTRY), str(self.root), str(self.artifacts)])
        self.assertEqual(options['stdin'], subprocess.DEVNULL)
        self.assertEqual(options['stdout'], subprocess.DEVNULL)
        self.assertEqual(options['stderr'], subprocess.DEVNULL)
        self.assertTrue(options['start_new_session'])
        self.assertTrue(options['close_fds'])

    def test_configuration_is_local_trusted_and_explicit(self):
        with self.assertRaises(ProcessorError):
            PDFProcessor(python_executable='/missing/interpreter', artifacts_directory=self.artifacts)
        symlink = self.root / 'linked-artifacts'; symlink.symlink_to(self.artifacts)
        with self.assertRaises(ProcessorError):
            PDFProcessor(python_executable=sys.executable, artifacts_directory=symlink)


if __name__ == '__main__':
    unittest.main()
