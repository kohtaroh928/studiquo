"""Explicit-start loopback-only prototype; not a publicly authenticated service.

A client must keep its write side open until the response. EOF (including TCP
half-close) or any extra byte after the declared PDF cancels the job. The trusted
runner must observe its cancellation event and enforce its own OS subprocess
limits: Python cannot forcibly stop a misbehaving thread. Closing this adapter
waits for runner cleanup rather than pretending Task.cancel stopped that thread.
"""
import asyncio
import hashlib
import json
import re
import threading

from runner import MAX_PDF_BYTES, MAX_RESPONSE_BYTES, PreparedResult, ProcessorError

MAX_HEADER_BYTES = 8192
RECEIVE_SECONDS = 10.0
WORK_SECONDS = 125.0
WRITE_SECONDS = 5.0
MAX_CONNECTIONS = 4


class _RequestError(Exception):
    def __init__(self, code='request_invalid', status=400):
        self.code, self.status = code, status


def _response(status, body, content_type='application/json'):
    if status == 204:
        return b'HTTP/1.1 204 No Content\r\nCache-Control: no-store\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n'
    reason = {200: 'OK', 400: 'Bad Request', 408: 'Request Timeout', 413: 'Content Too Large',
              500: 'Internal Server Error', 503: 'Service Unavailable', 504: 'Gateway Timeout'}[status]
    return (f'HTTP/1.1 {status} {reason}\r\nContent-Type: {content_type}\r\nContent-Length: {len(body)}\r\n'
            'Cache-Control: no-store\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n').encode('ascii') + body


def _error_response(code, status):
    return _response(status, json.dumps({'error': code}, separators=(',', ':')).encode('ascii'))


class PrivateHTTPProcessor:
    """Trusted processor dependency; only explicit start() creates a listener."""
    _bind_host = '127.0.0.1'
    _readiness_enabled = False

    def __init__(self, processor):
        self._processor = processor
        self._server = None
        self._port = None
        self._closing = False
        self._busy = False
        self._unavailable = False
        self._starting = False
        self._start_finished = asyncio.Event()
        self._start_finished.set()
        self._handlers = set()
        self._writers = set()
        self._cancel_events = set()

    @property
    def port(self):
        return self._port

    async def start(self, *, port=0):
        if self._server is not None or self._starting or self._closing or type(port) is not int or not 0 <= port <= 65535:
            raise ValueError('configuration_invalid')
        self._starting = True
        self._start_finished.clear()
        server = None
        try:
            server = await asyncio.start_server(self._accept, host=self._bind_host, port=port,
                                                limit=MAX_HEADER_BYTES, reuse_address=False)
            if self._closing:
                server.close()
                await server.wait_closed()
                raise ValueError('configuration_invalid')
            self._server = server
            self._port = server.sockets[0].getsockname()[1]
            return self
        finally:
            # A close racing startup waits until any newly opened listener is closed.
            if server is not None and self._server is not server:
                server.close()
            self._starting = False
            self._start_finished.set()

    async def close(self):
        self._closing = True
        await self._start_finished.wait()
        if self._server is not None:
            self._server.close()
        # Python 3.12 Server.wait_closed may wait for client transports. Cancel
        # their jobs before awaiting it, otherwise shutdown waits for full work.
        for event in tuple(self._cancel_events):
            event.set()
        for writer in tuple(self._writers):
            writer.close()
        handlers = tuple(self._handlers)
        for task in handlers:
            task.cancel()
        if handlers:
            await asyncio.gather(*handlers, return_exceptions=True)
        if self._server is not None:
            await self._server.wait_closed()

    async def __aenter__(self):
        return await self.start()

    async def __aexit__(self, *_):
        await self.close()

    def _accept(self, reader, writer):
        if self._closing or len(self._handlers) >= MAX_CONNECTIONS:
            try:
                writer.write(_error_response('busy', 503))
            except Exception:
                pass
            finally:
                writer.close()
            return
        self._writers.add(writer)
        task = asyncio.create_task(self._handle(reader, writer))
        self._handlers.add(task)
        task.add_done_callback(self._handlers.discard)

    async def _receive(self, reader, deadline):
        remaining = deadline - asyncio.get_running_loop().time()
        if remaining <= 0:
            raise _RequestError('receive_timeout', 408)
        try:
            header = await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), timeout=remaining)
        except asyncio.TimeoutError:
            raise _RequestError('receive_timeout', 408) from None
        except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, ValueError):
            raise _RequestError() from None
        if len(header) > MAX_HEADER_BYTES:
            raise _RequestError()
        try:
            lines = header[:-4].decode('ascii').split('\r\n')
        except UnicodeDecodeError:
            raise _RequestError() from None
        readiness = bool(lines and self._readiness_enabled and lines[0] == 'GET /ready HTTP/1.1')
        if not lines or (lines[0] != 'POST /parse HTTP/1.1' and not readiness):
            raise _RequestError()
        fields = {}
        for line in lines[1:]:
            match = re.fullmatch(r"([!#$%&'*+.^_`|~0-9A-Za-z-]+): *([ -~]*)", line)
            if match is None:
                raise _RequestError()
            key, value = match.group(1).lower(), match.group(2).strip(' ')
            if key in fields:
                raise _RequestError()
            fields[key] = value
        if (any(key in fields for key in ('transfer-encoding', 'content-encoding', 'expect'))
                or fields.get('host') != f'127.0.0.1:{self._port}'):
            raise _RequestError()
        if readiness:
            if fields.get('content-length', '0') != '0' or 'content-type' in fields:
                raise _RequestError()
            return 0
        if (fields.get('content-type', '').lower() != 'application/pdf'
                or not re.fullmatch('[1-9][0-9]{0,7}', fields.get('content-length', ''))):
            raise _RequestError()
        length = int(fields['content-length'])
        if length > MAX_PDF_BYTES:
            raise _RequestError('input_limit', 413)
        return length

    async def _run(self, reader, pdf, event):
        # Only this coroutine owns the runner Task; handler cancellation cannot cancel it.
        work = asyncio.create_task(asyncio.to_thread(self._processor.run_pdf, pdf, cancel_event=event))
        peer = asyncio.create_task(reader.read(1))
        try:
            done, _ = await asyncio.wait((work, peer), timeout=WORK_SECONDS, return_when=asyncio.FIRST_COMPLETED)
            if not done:
                raise _RequestError('work_timeout', 504)
            # Let an already-buffered extra byte/EOF win even when a fast runner also completed.
            await asyncio.sleep(0)
            if peer.done():
                try:
                    byte = peer.result()
                except Exception:
                    raise _RequestError('disconnected') from None
                raise _RequestError('extra_bytes' if byte else 'disconnected')
            try:
                result = work.result()
            except ProcessorError as error:
                allowed = {'input_invalid', 'cancelled', 'timeout', 'conversion_failed', 'output_invalid', 'cleanup_failed', 'configuration_invalid'}
                code = error.code if error.code in allowed else 'conversion_failed'
                if code == 'cleanup_failed':
                    self._unavailable = True
                raise _RequestError(code, 504 if code == 'timeout' else 500) from None
            except Exception:
                raise _RequestError('conversion_failed', 500) from None
            if (not isinstance(result, PreparedResult) or type(result.manifest) is not bytes
                    or not 0 < len(result.manifest) <= MAX_RESPONSE_BYTES
                    or result.pdf_sha256 != hashlib.sha256(pdf).hexdigest()
                    or type(result.total_pages) is not int or not 1 <= result.total_pages <= 20):
                raise _RequestError('output_invalid', 500)
            return result.manifest
        finally:
            event.set()
            peer.cancel()
            # No unshielded await may interrupt cleanup before runner completion.
            # Repeated cancellation must not release the slot while the native child is alive.
            while not work.done():
                try:
                    await asyncio.shield(work)
                except asyncio.CancelledError:
                    event.set()
                except Exception:
                    break
            if work.cancelled():
                self._unavailable = True
            elif work.done():
                late_error = work.exception()  # Retrieve without logging its contents.
                if isinstance(late_error, ProcessorError) and late_error.code == 'cleanup_failed':
                    self._unavailable = True

    async def _handle(self, reader, writer):
        owns_slot = False
        event = None
        response_started = False
        try:
            deadline = asyncio.get_running_loop().time() + RECEIVE_SECONDS
            length = await self._receive(reader, deadline)
            if self._unavailable:
                raise _RequestError('unavailable', 503)
            if self._closing or self._busy:
                raise _RequestError('busy', 503)
            if length == 0:
                response_started = True
                writer.write(_response(204, b''))
                await asyncio.wait_for(writer.drain(), timeout=WRITE_SECONDS)
                return
            self._busy = True
            owns_slot = True
            remaining = deadline - asyncio.get_running_loop().time()
            if remaining <= 0:
                raise _RequestError('receive_timeout', 408)
            try:
                pdf = await asyncio.wait_for(reader.readexactly(length), timeout=remaining)
            except asyncio.TimeoutError:
                raise _RequestError('receive_timeout', 408) from None
            except asyncio.IncompleteReadError:
                raise _RequestError('disconnected') from None
            if not pdf.startswith(b'%PDF-'):
                raise _RequestError('input_invalid')
            event = threading.Event()
            self._cancel_events.add(event)
            body = await self._run(reader, pdf, event)
            wire = _response(200, body, 'application/json')
            response_started = True
            writer.write(wire)
            await asyncio.wait_for(writer.drain(), timeout=WRITE_SECONDS)
        except _RequestError as error:
            if error.code != 'disconnected' and not response_started and not writer.is_closing():
                try:
                    response_started = True
                    writer.write(_error_response(error.code, error.status))
                    await asyncio.wait_for(writer.drain(), timeout=WRITE_SECONDS)
                except Exception:
                    pass
        except asyncio.CancelledError:
            if event is not None:
                event.set()
        except Exception:
            if not response_started and not writer.is_closing():
                try:
                    response_started = True
                    writer.write(_error_response('internal_error', 500))
                    await asyncio.wait_for(writer.drain(), timeout=WRITE_SECONDS)
                except Exception:
                    pass
        finally:
            if event is not None:
                event.set()
                self._cancel_events.discard(event)
            if owns_slot:
                self._busy = False
            self._writers.discard(writer)
            writer.close()
            try:
                await asyncio.wait_for(writer.wait_closed(), timeout=WRITE_SECONDS)
            except Exception:
                pass
