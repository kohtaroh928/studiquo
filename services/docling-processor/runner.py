"""Bounded local conversion boundary. No HTTP, credentials, URLs or user commands."""
from dataclasses import dataclass
import hashlib
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import tempfile
import threading
import time
from validation import validate_manifest

MAX_PDF_BYTES = 10 * 1024 * 1024
MAX_RESPONSE_BYTES = 4 * 1024 * 1024
MAX_PAGES = 20
DEADLINE_SECONDS = 120.0
_CHILD_ENTRY = Path(__file__).with_name('child_entry.py').resolve()


class ProcessorError(Exception):
    """Fixed public code only; never expose parser errors, paths or document text."""
    def __init__(self, code):
        self.code = code
        super().__init__(code)


@dataclass(frozen=True)
class PreparedResult:
    manifest: bytes
    pdf_sha256: str
    total_pages: int


class PDFProcessor:
    """Python/artifact paths are trusted service configuration, never request input."""
    def __init__(self, *, python_executable, artifacts_directory, temporary_root=None):
        self._python = Path(python_executable).absolute()
        self._artifacts = Path(artifacts_directory).absolute()
        self._temporary_root = temporary_root
        if (not self._python.is_file() or not os.access(self._python, os.X_OK)
                or not self._artifacts.is_dir() or self._artifacts.is_symlink()):
            raise ProcessorError('configuration_invalid')

    def run_pdf(self, pdf_bytes, *, cancel_event=None):
        if type(pdf_bytes) is not bytes or not 0 < len(pdf_bytes) <= MAX_PDF_BYTES or not pdf_bytes.startswith(b'%PDF-'):
            raise ProcessorError('input_invalid')
        if cancel_event is not None and not isinstance(cancel_event, threading.Event):
            raise ProcessorError('input_invalid')
        deadline = time.monotonic() + DEADLINE_SECONDS
        job = None
        process = None
        try:
            self._check(deadline, cancel_event)
            job = Path(tempfile.mkdtemp(prefix='studiquo-docling-', dir=self._temporary_root))
            os.chmod(job, 0o700)
            fd = os.open(job / 'input.pdf', os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, 'wb') as stream:
                stream.write(pdf_bytes)
            self._check(deadline, cancel_event)
            environment = {
                'PATH': os.defpath, 'HOME': str(job), 'TMPDIR': str(job), 'LANG': 'C.UTF-8',
                'HF_HUB_OFFLINE': '1', 'TRANSFORMERS_OFFLINE': '1', 'HF_HUB_DISABLE_TELEMETRY': '1',
                'DO_NOT_TRACK': '1', 'TOKENIZERS_PARALLELISM': 'false',
                'OMP_NUM_THREADS': '1', 'OPENBLAS_NUM_THREADS': '1', 'MKL_NUM_THREADS': '1',
            }
            process = self._launch(job, environment)
            while True:
                self._check(deadline, cancel_event)
                remaining = max(0.001, deadline - time.monotonic())
                try:
                    code = process.wait(timeout=min(0.025, remaining))
                    break
                except subprocess.TimeoutExpired:
                    continue
            if code != 0:
                raise ProcessorError('conversion_failed')
            self._check(deadline, cancel_event)
            fd = os.open(job / 'prepared.json', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, 'rb') as stream:
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600 or not 0 < info.st_size <= MAX_RESPONSE_BYTES:
                    raise ProcessorError('output_invalid')
                manifest = stream.read(MAX_RESPONSE_BYTES + 1)
            if len(manifest) > MAX_RESPONSE_BYTES:
                raise ProcessorError('output_invalid')
            digest = hashlib.sha256(pdf_bytes).hexdigest()
            try:
                total = validate_manifest(manifest, digest)
            except Exception:
                raise ProcessorError('output_invalid') from None
            self._check(deadline, cancel_event)
            return PreparedResult(manifest=manifest, pdf_sha256=digest, total_pages=total)
        except ProcessorError:
            raise
        except Exception:
            raise ProcessorError('conversion_failed') from None
        finally:
            cleanup_failed = False
            if process is not None:
                # Kill the entire session even if the leader exited but left descendants.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                except OSError:
                    cleanup_failed = True
                try:
                    process.wait(timeout=2)
                except Exception:
                    cleanup_failed = True
            if job is not None:
                try:
                    shutil.rmtree(job)
                except OSError:
                    cleanup_failed = True
            if cleanup_failed:
                raise ProcessorError('cleanup_failed') from None

    def _launch(self, job, environment):
        return subprocess.Popen(
            [str(self._python), '-I', '-B', str(_CHILD_ENTRY), str(job), str(self._artifacts)],
            cwd=job, env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True,
        )

    @staticmethod
    def _check(deadline, cancel_event):
        if cancel_event is not None and cancel_event.is_set():
            raise ProcessorError('cancelled')
        if time.monotonic() >= deadline:
            raise ProcessorError('timeout')
