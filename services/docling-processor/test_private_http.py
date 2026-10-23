"""Loopback-only synthetic PDF adapter contract tests; no remote services/models."""
import asyncio
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

import private_http
from private_http import PrivateHTTPProcessor
from runner import PDFProcessor, PreparedResult, ProcessorError

PDF = b'%PDF-1.7\nSynthetic HTTP contract only'


class MockProcessor:
    def __init__(self, *, block=False, cleanup_delay=0, error=None, oversized=False):
        self.block = block; self.cleanup_delay = cleanup_delay; self.error = error; self.oversized = oversized
        self.started = threading.Event(); self.cancelled = threading.Event(); self.finished = threading.Event()
        self.calls = 0

    def run_pdf(self, pdf, *, cancel_event):
        self.calls += 1; self.started.set()
        if self.block:
            cancel_event.wait(3)
        if cancel_event.is_set():
            self.cancelled.set()
            time.sleep(self.cleanup_delay)
        self.finished.set()
        if self.error:
            raise self.error
        return PreparedResult(manifest=b'x' * (private_http.MAX_RESPONSE_BYTES + 1) if self.oversized else b'{"synthetic":true}',
                              pdf_sha256=hashlib.sha256(pdf).hexdigest(), total_pages=1)


async def eventually(predicate, timeout=2):
    deadline = asyncio.get_running_loop().time() + timeout
    while not predicate():
        if asyncio.get_running_loop().time() > deadline:
            raise AssertionError('condition did not complete')
        await asyncio.sleep(.005)


class PrivateHTTPTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.processor = MockProcessor()
        self.adapter = await PrivateHTTPProcessor(self.processor).start()
        self.clients = []

    async def asyncTearDown(self):
        for _, writer in self.clients:
            writer.close()
        await self.adapter.close()

    async def connect(self):
        reader, writer = await asyncio.open_connection('127.0.0.1', self.adapter.port)
        self.clients.append((reader, writer))
        return reader, writer

    def header(self, *, length=len(PDF), extra='', path='/parse', method='POST', host=None, type_='application/pdf'):
        host = host or f'127.0.0.1:{self.adapter.port}'
        return (f'{method} {path} HTTP/1.1\r\nHost: {host}\r\nContent-Type: {type_}\r\n'
                f'Content-Length: {length}\r\n{extra}\r\n').encode()

    async def request(self, wire):
        reader, writer = await self.connect()
        writer.write(wire); await writer.drain()
        async def response():
            header = await reader.readuntil(b'\r\n\r\n')
            length_line = next(line for line in header.split(b'\r\n') if line.lower().startswith(b'content-length:'))
            length = int(length_line.split(b':', 1)[1].strip())
            return header + await reader.readexactly(length)
        return await asyncio.wait_for(response(), 2)

    async def test_success_loopback_response_no_store_and_close(self):
        self.assertEqual(self.adapter._server.sockets[0].getsockname()[0], '127.0.0.1')
        response = await self.request(self.header() + PDF)
        self.assertTrue(response.startswith(b'HTTP/1.1 200'))
        self.assertIn(b'Cache-Control: no-store\r\n', response)
        self.assertIn(b'Connection: close\r\n', response)
        self.assertTrue(response.endswith(b'{"synthetic":true}'))
        self.assertEqual(self.processor.calls, 1)

    async def test_wrong_method_path_query_host_and_type_rejected(self):
        for header in [self.header(method='GET'), self.header(path='/parse?url=x'), self.header(path='http://127.0.0.1/parse'),
                       self.header(host='evil.example'), self.header(host='localhost'), self.header(type_='application/pdf; charset=utf-8')]:
            self.assertTrue((await self.request(header + PDF)).startswith(b'HTTP/1.1 400'))
        self.assertEqual(self.processor.calls, 0)

    async def test_duplicate_forbidden_and_folded_headers_rejected(self):
        for extra in ['Content-Length: 5\r\n', 'HOST: duplicate\r\n', 'Transfer-Encoding: chunked\r\n',
                      'Content-Encoding: identity\r\n', 'Expect: 100-continue\r\n', ' folded: x\r\n', 'X: a\tb\r\n']:
            self.assertTrue((await self.request(self.header(extra=extra) + PDF)).startswith(b'HTTP/1.1 400'))
        self.assertEqual(self.processor.calls, 0)

    async def test_missing_nondecimal_zero_and_oversized_length(self):
        for value in ['0', '-1', '01', '+2', '1,1', '1e2']:
            response = await self.request(self.header(length=value) + PDF)
            self.assertTrue(response.startswith(b'HTTP/1.1 400'))
        self.assertTrue((await self.request(self.header(length=10 * 1024 * 1024 + 1))).startswith(b'HTTP/1.1 413'))
        missing = self.header().replace(f'Content-Length: {len(PDF)}\r\n'.encode(), b'')
        self.assertTrue((await self.request(missing + PDF)).startswith(b'HTTP/1.1 400'))
        self.assertEqual(self.processor.calls, 0)

    async def test_header_limit_includes_delimiter(self):
        prefix = self.header(extra='X: ')
        response = await self.request(prefix[:-2] + b'a' * 8192 + b'\r\n\r\n')
        self.assertTrue(response.startswith(b'HTTP/1.1 400'))
        self.assertEqual(self.processor.calls, 0)

    async def test_header_and_body_share_total_receive_deadline(self):
        with patch.object(private_http, 'RECEIVE_SECONDS', .1):
            reader, writer = await self.connect()
            writer.write(self.header()); await writer.drain()
            await asyncio.sleep(.12)
            response = await asyncio.wait_for(reader.read(), 1)
        self.assertTrue(response.startswith(b'HTTP/1.1 408'))
        self.assertEqual(self.processor.calls, 0)

    async def test_header_slowloris_has_deadline(self):
        with patch.object(private_http, 'RECEIVE_SECONDS', .05):
            response = await self.request(b'POST /parse HTTP/1.1\r\n')
        self.assertTrue(response.startswith(b'HTTP/1.1 408'))

    async def test_truncated_body_and_invalid_pdf_do_not_run(self):
        reader, writer = await self.connect()
        writer.write(self.header() + PDF[:2]); await writer.drain(); writer.write_eof()
        self.assertEqual(await asyncio.wait_for(reader.read(), 1), b'')
        response = await self.request(self.header(length=5) + b'bad!!')
        self.assertTrue(response.startswith(b'HTTP/1.1 400'))
        self.assertEqual(self.processor.calls, 0)

    async def test_pipeline_and_extra_byte_cancel_job(self):
        self.processor.block = True
        response = await self.request(self.header() + PDF + b'POST /parse HTTP/1.1\r\n')
        self.assertTrue(response.startswith(b'HTTP/1.1 400'))
        self.assertIn(b'extra_bytes', response)
        self.assertTrue(self.processor.cancelled.is_set())
        self.assertTrue(self.processor.finished.is_set())

    async def test_disconnect_and_halfclose_cancel_and_hold_slot_until_cleanup(self):
        self.processor.block = True; self.processor.cleanup_delay = .15
        reader, writer = await self.connect()
        writer.write(self.header() + PDF); await writer.drain()
        await eventually(self.processor.started.is_set)
        writer.write_eof()
        await eventually(self.processor.cancelled.is_set)
        response = await self.request(self.header() + PDF)
        self.assertTrue(response.startswith(b'HTTP/1.1 503'))
        self.assertTrue(self.adapter._busy)
        self.assertEqual(await asyncio.wait_for(reader.read(), 1), b'')
        self.assertTrue(self.processor.finished.is_set())
        await eventually(lambda: not self.adapter._busy)

    async def test_job_busy_rejects_before_reading_body(self):
        self.processor.block = True
        _, writer = await self.connect(); writer.write(self.header() + PDF); await writer.drain()
        await eventually(self.processor.started.is_set)
        response = await self.request(self.header())
        self.assertTrue(response.startswith(b'HTTP/1.1 503'))
        self.assertEqual(self.processor.calls, 1)

    async def test_connection_cap_does_not_allocate_extra_handler(self):
        for _ in range(4): await self.connect()
        await eventually(lambda: len(self.adapter._handlers) == 4)
        response = await self.request(b'')
        self.assertTrue(response.startswith(b'HTTP/1.1 503'))
        self.assertEqual(len(self.adapter._handlers), 4)

    async def test_work_deadline_waits_for_cancellation_cleanup(self):
        self.processor.block = True; self.processor.cleanup_delay = .05
        with patch.object(private_http, 'WORK_SECONDS', .05):
            response = await self.request(self.header() + PDF)
        self.assertTrue(response.startswith(b'HTTP/1.1 504'))
        self.assertTrue(self.processor.cancelled.is_set())
        self.assertTrue(self.processor.finished.is_set())

    async def test_shutdown_waits_for_runner_and_no_new_listener(self):
        self.processor.block = True; self.processor.cleanup_delay = .05
        _, writer = await self.connect(); writer.write(self.header() + PDF); await writer.drain()
        await eventually(self.processor.started.is_set)
        await self.adapter.close()
        self.assertTrue(self.processor.cancelled.is_set())
        self.assertTrue(self.processor.finished.is_set())
        self.assertFalse(self.adapter._busy)
        with self.assertRaises(ValueError): await self.adapter.start()

    async def test_fixed_failure_and_output_limit_no_details(self):
        self.processor.error = RuntimeError('SYNTHETIC_BODY_MARKER')
        response = await self.request(self.header() + PDF)
        self.assertTrue(response.startswith(b'HTTP/1.1 500'))
        self.assertNotIn(b'SYNTHETIC_BODY_MARKER', response)
        self.processor.error = None; self.processor.oversized = True
        response = await self.request(self.header() + PDF)
        self.assertIn(b'output_invalid', response)

    async def test_cleanup_failure_poisons_listener(self):
        self.processor.error = ProcessorError('cleanup_failed')
        response = await self.request(self.header() + PDF)
        self.assertIn(b'cleanup_failed', response)
        response = await self.request(self.header() + PDF)
        self.assertTrue(response.startswith(b'HTTP/1.1 503'))
        self.assertIn(b'unavailable', response)
        self.assertEqual(self.processor.calls, 1)

    async def test_repeated_handler_cancel_keeps_slot_until_actual_runner_exit(self):
        self.processor.block = True; self.processor.cleanup_delay = .15
        _, writer = await self.connect(); writer.write(self.header() + PDF); await writer.drain()
        await eventually(self.processor.started.is_set)
        handler = next(iter(self.adapter._handlers))
        handler.cancel()
        await eventually(self.processor.cancelled.is_set)
        handler.cancel(); await asyncio.sleep(.01); handler.cancel()
        self.assertTrue(self.adapter._busy)
        self.assertFalse(self.processor.finished.is_set())
        response = await self.request(self.header())
        self.assertTrue(response.startswith(b'HTTP/1.1 503'))
        await eventually(self.processor.finished.is_set)
        await eventually(lambda: not self.adapter._busy)

    async def test_late_cleanup_failure_after_disconnect_poisons_service(self):
        self.processor.block = True; self.processor.error = ProcessorError('cleanup_failed')
        reader, writer = await self.connect(); writer.write(self.header() + PDF); await writer.drain()
        await eventually(self.processor.started.is_set)
        writer.write_eof()
        self.assertEqual(await asyncio.wait_for(reader.read(), 1), b'')
        await eventually(lambda: self.adapter._unavailable)
        response = await self.request(self.header() + PDF)
        self.assertIn(b'unavailable', response)
        self.assertEqual(self.processor.calls, 1)

    async def test_real_runner_cancel_terminates_child_and_removes_private_job(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); artifacts = root / 'artifacts'; artifacts.mkdir()
            jobs = root / 'jobs'; jobs.mkdir()
            processor = PDFProcessor(python_executable=sys.executable, artifacts_directory=artifacts, temporary_root=jobs)
            children = []
            def launch(job, environment):
                process = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'], cwd=job,
                                           env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                           stderr=subprocess.DEVNULL, start_new_session=True)
                children.append(process)
                return process
            self.adapter._processor = processor
            with patch.object(processor, '_launch', side_effect=launch):
                _, writer = await self.connect(); writer.write(self.header() + PDF); await writer.drain()
                await eventually(lambda: len(children) == 1)
                writer.close()
                await eventually(lambda: not self.adapter._busy)
            self.assertIsNotNone(children[0].poll())
            self.assertEqual(list(jobs.iterdir()), [])


class LifecycleTests(unittest.IsolatedAsyncioTestCase):
    async def test_concurrent_start_is_rejected_without_duplicate_listener(self):
        adapter = PrivateHTTPProcessor(MockProcessor())
        entered, release = asyncio.Event(), asyncio.Event()
        class Server:
            sockets = [type('Socket', (), {'getsockname': lambda _: ('127.0.0.1', 12345)})()]
            closed = False
            def close(self): self.closed = True
            async def wait_closed(self): pass
        server = Server()
        async def start(*args, **kwargs):
            entered.set(); await release.wait(); return server
        with patch.object(private_http.asyncio, 'start_server', side_effect=start) as factory:
            first = asyncio.create_task(adapter.start()); await entered.wait()
            with self.assertRaises(ValueError): await adapter.start()
            release.set(); await first; await adapter.close()
            self.assertEqual(factory.call_count, 1)
            self.assertTrue(server.closed)

    async def test_close_during_start_waits_and_closes_late_listener(self):
        adapter = PrivateHTTPProcessor(MockProcessor())
        entered, release = asyncio.Event(), asyncio.Event()
        class Server:
            sockets = []
            closed = False
            def close(self): self.closed = True
            async def wait_closed(self): pass
        server = Server()
        async def start(*args, **kwargs):
            entered.set(); await release.wait(); return server
        with patch.object(private_http.asyncio, 'start_server', side_effect=start):
            first = asyncio.create_task(adapter.start()); await entered.wait()
            close = asyncio.create_task(adapter.close()); await asyncio.sleep(0)
            self.assertFalse(close.done())
            release.set()
            with self.assertRaises(ValueError): await first
            await close
            self.assertTrue(server.closed)
            self.assertIsNone(adapter._server)

    async def test_shutdown_signals_cancel_before_waiting_for_client_transports(self):
        adapter = PrivateHTTPProcessor(MockProcessor())
        event = threading.Event(); adapter._cancel_events.add(event)
        testcase = self
        class Server:
            def close(self): pass
            async def wait_closed(self): testcase.assertTrue(event.is_set())
        adapter._server = Server()
        await adapter.close()

    async def _memory_request(self, adapter, raw):
        reader = asyncio.StreamReader(); reader.feed_data(raw)
        class Writer:
            def __init__(self): self.chunks = []; self.closing = False
            def write(self, data): self.chunks.append(data)
            async def drain(self): pass
            def is_closing(self): return self.closing
            def close(self): self.closing = True
            async def wait_closed(self): pass
        writer = Writer()
        await adapter._handle(reader, writer)
        return b''.join(writer.chunks)

    async def test_readiness_only_explicit_container_and_no_body_or_job(self):
        from container_entry import ContainerHTTPProcessor
        processor = MockProcessor()
        adapter = ContainerHTTPProcessor(processor); adapter._port = 8080
        response = await self._memory_request(adapter, b'GET /ready HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n\r\n')
        self.assertTrue(response.startswith(b'HTTP/1.1 204'))
        self.assertTrue(response.endswith(b'\r\n\r\n'))
        self.assertIn(b'Cache-Control: no-store', response)
        self.assertNotIn(b'Content-Length', response)
        self.assertEqual(processor.calls, 0)
        self.assertFalse(adapter._busy)
        base = PrivateHTTPProcessor(processor); base._port = 8080
        response = await self._memory_request(base, b'GET /ready HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n\r\n')
        self.assertTrue(response.startswith(b'HTTP/1.1 400'))

    async def test_container_readiness_rejects_body_encoding_queries_and_host(self):
        from container_entry import ContainerHTTPProcessor
        processor = MockProcessor(); adapter = ContainerHTTPProcessor(processor); adapter._port = 8080
        requests = [b'GET /ready?x=1 HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n\r\n',
                    b'GET /ready HTTP/1.1\r\nHost: localhost:8080\r\n\r\n']
        for extra in [b'Content-Length: 1\r\n', b'Transfer-Encoding: chunked\r\n', b'Content-Encoding: identity\r\n', b'Expect: 100-continue\r\n', b'Content-Type: application/pdf\r\n', b'Host: duplicate\r\n']:
            requests.append(b'GET /ready HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n' + extra + b'\r\n')
        for request in requests:
            response = await self._memory_request(adapter, request)
            self.assertTrue(response.startswith(b'HTTP/1.1 400'))
        self.assertEqual(processor.calls, 0)

    async def test_container_ready_busy_or_poisoned_returns_unavailable(self):
        from container_entry import ContainerHTTPProcessor
        processor = MockProcessor(); adapter = ContainerHTTPProcessor(processor); adapter._port = 8080
        request = b'GET /ready HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n\r\n'
        adapter._busy = True
        response = await self._memory_request(adapter, request)
        self.assertTrue(response.startswith(b'HTTP/1.1 503'))
        adapter._busy = False; adapter._unavailable = True
        response = await self._memory_request(adapter, request)
        self.assertTrue(response.startswith(b'HTTP/1.1 503'))
        self.assertIn(b'unavailable', response)
        self.assertEqual(processor.calls, 0)

    async def test_container_parse_keeps_existing_strict_contract(self):
        from container_entry import ContainerHTTPProcessor
        processor = MockProcessor(); adapter = ContainerHTTPProcessor(processor); adapter._port = 8080
        request = (f'POST /parse HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nContent-Type: application/pdf\r\nContent-Length: {len(PDF)}\r\n\r\n').encode() + PDF
        response = await self._memory_request(adapter, request)
        self.assertTrue(response.startswith(b'HTTP/1.1 200'))
        self.assertEqual(processor.calls, 1)
        response = await self._memory_request(adapter, request.replace(b'application/pdf', b'text/plain'))
        self.assertTrue(response.startswith(b'HTTP/1.1 400'))
        self.assertEqual(processor.calls, 1)

    async def test_success_write_failure_never_appends_error_response(self):
        adapter = PrivateHTTPProcessor(MockProcessor()); adapter._port = 12345
        reader = asyncio.StreamReader()
        reader.feed_data((f'POST /parse HTTP/1.1\r\nHost: 127.0.0.1:12345\r\nContent-Type: application/pdf\r\nContent-Length: {len(PDF)}\r\n\r\n').encode() + PDF)
        class Writer:
            chunks = []
            closing = False
            def write(self, data): self.chunks.append(data)
            async def drain(self): raise asyncio.TimeoutError()
            def is_closing(self): return self.closing
            def close(self): self.closing = True
            async def wait_closed(self): pass
        writer = Writer()
        await adapter._handle(reader, writer)
        self.assertEqual(len(writer.chunks), 1)
        self.assertTrue(writer.chunks[0].startswith(b'HTTP/1.1 200'))
        self.assertNotIn(b'HTTP/1.1 500', writer.chunks[0])
        self.assertFalse(adapter._busy)


if __name__ == '__main__':
    unittest.main()
