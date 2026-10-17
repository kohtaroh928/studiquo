"""Synthetic-only startup cleanup, fixed binding and signal lifecycle tests."""
import asyncio
import importlib.metadata
import os
from pathlib import Path
import signal
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

import container_entry as entry
from private_http import PrivateHTTPProcessor
from test_private_http import MockProcessor


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / 'jobs'

    def tearDown(self):
        self.temp.cleanup()

    def job(self, name='studiquo-docling-abcdefgh'):
        self.root.mkdir(mode=0o700, exist_ok=True)
        job = self.root / name; job.mkdir(mode=0o700)
        return job

    def private_file(self, path, content=b'Synthetic only'):
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, 'wb') as stream: stream.write(content)

    def test_creates_private_root_without_removing_it(self):
        entry.cleanup_orphan_jobs(self.root)
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o700)
        self.assertEqual(list(self.root.iterdir()), [])
        entry.cleanup_orphan_jobs(self.root)
        self.assertTrue(self.root.is_dir())

    def test_removes_only_valid_private_job_trees(self):
        for index in ('abcdefgh', 'ijklmnop'):
            job = self.job('studiquo-docling-' + index)
            nested = job / 'native-cache'; nested.mkdir(mode=0o700)
            self.private_file(job / 'input.pdf'); self.private_file(nested / 'cache.bin')
        entry.cleanup_orphan_jobs(self.root)
        self.assertTrue(self.root.is_dir()); self.assertEqual(list(self.root.iterdir()), [])

    def test_unknown_entry_rejected_before_any_valid_job_is_deleted(self):
        job = self.job(); self.private_file(job / 'input.pdf')
        self.private_file(self.root / 'operator-file')
        with self.assertRaisesRegex(entry.StartupError, '^job_cleanup_failed$'):
            entry.cleanup_orphan_jobs(self.root)
        self.assertTrue((job / 'input.pdf').exists())
        self.assertTrue((self.root / 'operator-file').exists())

    def test_symlink_root_or_child_is_never_followed(self):
        outside = Path(self.temp.name) / 'outside'; outside.mkdir(mode=0o700)
        self.private_file(outside / 'sentinel')
        self.root.symlink_to(outside)
        with self.assertRaises(entry.StartupError): entry.cleanup_orphan_jobs(self.root)
        self.assertTrue((outside / 'sentinel').exists())
        self.root.unlink()
        job = self.job(); (job / 'linked').symlink_to(outside)
        with self.assertRaises(entry.StartupError): entry.cleanup_orphan_jobs(self.root)
        self.assertTrue((outside / 'sentinel').exists()); self.assertTrue((job / 'linked').is_symlink())

    def test_wrong_modes_owner_and_hardlinks_fail_closed(self):
        job = self.job(); self.private_file(job / 'input.pdf')
        (job / 'input.pdf').chmod(0o644)
        with self.assertRaises(entry.StartupError): entry.cleanup_orphan_jobs(self.root)
        (job / 'input.pdf').chmod(0o600)
        with patch.object(entry.os, 'geteuid', return_value=os.geteuid() + 1):
            with self.assertRaises(entry.StartupError): entry.cleanup_orphan_jobs(self.root)
        outside = Path(self.temp.name) / 'linked-copy'; os.link(job / 'input.pdf', outside)
        with self.assertRaises(entry.StartupError): entry.cleanup_orphan_jobs(self.root)
        self.assertTrue(outside.exists()); self.assertTrue((job / 'input.pdf').exists())
        outside.unlink(); self.root.chmod(0o755)
        with self.assertRaises(entry.StartupError): entry.cleanup_orphan_jobs(self.root)
        self.assertTrue((job / 'input.pdf').exists())

    def test_depth_entries_and_size_budget_fail_before_removal(self):
        job = self.job(); self.private_file(job / 'input.pdf')
        nested = job / 'nested'; nested.mkdir(mode=0o700)
        self.private_file(nested / 'cache')
        for name, limit in [('MAX_ORPHAN_DEPTH', 0), ('MAX_ORPHAN_ENTRIES', 1), ('MAX_ORPHAN_BYTES', 1)]:
            with patch.object(entry, name, limit):
                with self.assertRaises(entry.StartupError): entry.cleanup_orphan_jobs(self.root)
            self.assertTrue((job / 'input.pdf').exists())

    def test_inode_change_fails_closed(self):
        job = self.job(); self.private_file(job / 'input.pdf')
        original = entry._identity
        calls = 0
        def changed(info):
            nonlocal calls
            calls += 1
            result = original(info)
            return (result[0], result[1] + 1, *result[2:]) if calls == 2 else result
        with patch.object(entry, '_identity', side_effect=changed):
            with self.assertRaises(entry.StartupError): entry.cleanup_orphan_jobs(self.root)
        self.assertTrue((job / 'input.pdf').exists())


class InstallationTests(unittest.TestCase):
    def test_fixed_location_and_version_required(self):
        with self.assertRaisesRegex(entry.StartupError, '^configuration_invalid$'): entry.verify_installation()
        with patch.object(entry, 'CODE_DIRECTORY', Path(entry.__file__).resolve().parent), patch.object(importlib.metadata, 'version', return_value='other'):
            with self.assertRaises(entry.StartupError): entry.verify_installation()

    def test_wrong_regex_version_rejected_before_artifact_validation(self):
        fake = types.SimpleNamespace(validate_artifacts=lambda _: self.fail('must reject mismatched tokenizer first'))
        with patch.object(entry, 'CODE_DIRECTORY', Path(entry.__file__).resolve().parent), patch.object(importlib.metadata, 'version', side_effect=lambda name: {'docling': '2.139.0', 'regex': 'other'}[name]), patch.dict(sys.modules, {'extract_pdf': fake}):
            with self.assertRaisesRegex(entry.StartupError, '^configuration_invalid$'):
                entry.verify_installation()

    def test_pinned_install_checks_existing_artifacts_without_model_import(self):
        calls = []
        fake = types.SimpleNamespace(validate_artifacts=lambda path: calls.append(path))
        with patch.object(entry, 'CODE_DIRECTORY', Path(entry.__file__).resolve().parent), patch.object(importlib.metadata, 'version', side_effect=lambda name: {'docling': '2.139.0', 'regex': '2026.9.29'}[name]), patch.dict(sys.modules, {'extract_pdf': fake}):
            entry.verify_installation()
        self.assertEqual(calls, ['/opt/docling-models'])


class ContainerLifecycleTests(unittest.IsolatedAsyncioTestCase):
    async def test_explicit_container_class_has_fixed_bind_and_port(self):
        adapter = entry.ContainerHTTPProcessor(MockProcessor())
        with patch.object(PrivateHTTPProcessor, 'start', return_value=adapter) as start:
            self.assertIs(await adapter.start(), adapter)
            start.assert_awaited_once_with(port=8080)
        self.assertEqual(adapter._bind_host, '0.0.0.0')
        self.assertEqual(PrivateHTTPProcessor._bind_host, '127.0.0.1')
        with self.assertRaises(TypeError): await adapter.start(port=1234)

    async def test_signal_shutdown_awaits_adapter_close_and_uses_fixed_paths(self):
        calls, callbacks = [], {}
        class Adapter:
            def __init__(self, processor): calls.append(('adapter', processor))
            async def start(self):
                calls.append('start'); callbacks[signal.SIGTERM]()
            async def close(self):
                await asyncio.sleep(0); calls.append('closed')
        loop = asyncio.get_running_loop()
        def add(value, callback): callbacks[value] = callback
        with patch.object(entry, 'verify_installation') as verify, patch.object(entry, 'cleanup_orphan_jobs') as cleanup, patch.object(entry, 'PDFProcessor', return_value='fixed-runner') as runner, patch.object(entry, 'ContainerHTTPProcessor', Adapter), patch.object(loop, 'add_signal_handler', side_effect=add), patch.object(loop, 'remove_signal_handler') as remove:
            await entry.serve()
        verify.assert_called_once_with(); cleanup.assert_called_once_with()
        runner.assert_called_once_with(python_executable=Path('/opt/docling-env/bin/python'), artifacts_directory=Path('/opt/docling-models'), temporary_root=Path('/tmp/studiquo-docling-jobs'))
        self.assertEqual(calls[-1], 'closed')
        self.assertEqual(remove.call_count, 2)

    async def test_failed_start_still_closes_adapter_and_removes_signals(self):
        calls = []
        class Adapter:
            def __init__(self, _): pass
            async def start(self): raise OSError('SYNTHETIC_ONLY')
            async def close(self): calls.append('closed')
        loop = asyncio.get_running_loop()
        with patch.object(entry, 'verify_installation'), patch.object(entry, 'cleanup_orphan_jobs'), patch.object(entry, 'PDFProcessor'), patch.object(entry, 'ContainerHTTPProcessor', Adapter), patch.object(loop, 'add_signal_handler'), patch.object(loop, 'remove_signal_handler') as remove:
            with self.assertRaises(OSError): await entry.serve()
        self.assertEqual(calls, ['closed']); self.assertEqual(remove.call_count, 2)


    async def test_close_failure_still_removes_signal_handlers(self):
        callbacks = {}
        class Adapter:
            def __init__(self, _): pass
            async def start(self): callbacks[signal.SIGINT]()
            async def close(self): raise RuntimeError('SYNTHETIC_ONLY')
        loop = asyncio.get_running_loop()
        with patch.object(entry, 'verify_installation'), patch.object(entry, 'cleanup_orphan_jobs'), patch.object(entry, 'PDFProcessor'), patch.object(entry, 'ContainerHTTPProcessor', Adapter), patch.object(loop, 'add_signal_handler', side_effect=lambda value, callback: callbacks.update({value: callback})), patch.object(loop, 'remove_signal_handler') as remove:
            with self.assertRaises(RuntimeError): await entry.serve()
        self.assertEqual(remove.call_count, 2)


if __name__ == '__main__':
    unittest.main()
