"""Explicit fixed-image entrypoint; it never installs packages or downloads models.

The all-interface listener is only for an isolated container's private ingress.
It is not an authentication boundary or permission to publish port 8080.
"""
import asyncio
import importlib.metadata
import os
from pathlib import Path
import re
import signal
import stat
import sys

# -I deliberately removes the script directory from sys.path. Only restore the
# deployment-owned code directory, never cwd/PYTHONPATH or a request path.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from private_http import PrivateHTTPProcessor
from runner import PDFProcessor

CODE_DIRECTORY = Path('/app/services/docling-processor')
PYTHON_EXECUTABLE = Path('/opt/docling-env/bin/python')
ARTIFACTS_DIRECTORY = Path('/opt/docling-models')
JOB_ROOT = Path('/tmp/studiquo-docling-jobs')
MAX_ORPHAN_ENTRIES = 10000
MAX_ORPHAN_DEPTH = 16
MAX_ORPHAN_BYTES = 256 * 1024 * 1024
_JOB_NAME = re.compile(r'studiquo-docling-[a-z0-9_]{8}')


class StartupError(Exception):
    """Only fixed codes are exposed; no paths or exception details are logged."""


class ContainerHTTPProcessor(PrivateHTTPProcessor):
    _bind_host = '0.0.0.0'
    _readiness_enabled = True

    async def start(self):
        return await super().start(port=8080)


def _identity(info):
    return info.st_dev, info.st_ino, info.st_mode, info.st_uid


def _private(info, *, directory):
    valid_kind = stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)
    if (not valid_kind or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != (0o700 if directory else 0o600)
            or not directory and info.st_nlink != 1):
        raise StartupError('job_cleanup_failed')


def _names(fd):
    names = []
    with os.scandir(fd) as iterator:
        for entry in iterator:
            if len(names) >= MAX_ORPHAN_ENTRIES:
                raise StartupError('job_cleanup_failed')
            names.append(entry.name)
    return names


def cleanup_orphan_jobs(root=JOB_ROOT):
    """FD-relative no-follow walk; reject unknown entries before deleting any job.

    Only a deployment-owned dedicated root is valid. This function never removes
    the root itself. It cannot guarantee physical erasure or survive host death.
    """
    root = Path(root)
    root_fd = None
    try:
        try:
            os.mkdir(root, 0o700)
        except FileExistsError:
            pass
        root_info = root.lstat()
        _private(root_info, directory=True)
        root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        if _identity(os.fstat(root_fd)) != _identity(root_info):
            raise StartupError('job_cleanup_failed')
        entries, byte_count = 0, 0

        def scan(fd, depth):
            nonlocal entries, byte_count
            if depth > MAX_ORPHAN_DEPTH:
                raise StartupError('job_cleanup_failed')
            result = []
            for name in _names(fd):
                entries += 1
                if entries > MAX_ORPHAN_ENTRIES:
                    raise StartupError('job_cleanup_failed')
                info = os.stat(name, dir_fd=fd, follow_symlinks=False)
                directory = stat.S_ISDIR(info.st_mode)
                _private(info, directory=directory)
                byte_count += info.st_size if not directory else 0
                if byte_count > MAX_ORPHAN_BYTES:
                    raise StartupError('job_cleanup_failed')
                children = None
                if directory:
                    child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                    try:
                        if _identity(os.fstat(child)) != _identity(info):
                            raise StartupError('job_cleanup_failed')
                        children = scan(child, depth + 1)
                    finally:
                        os.close(child)
                result.append((name, info, children))
            return result

        names = _names(root_fd)
        if len(names) > MAX_ORPHAN_ENTRIES:
            raise StartupError('job_cleanup_failed')
        for name in names:
            if not _JOB_NAME.fullmatch(name):
                raise StartupError('job_cleanup_failed')
            _private(os.stat(name, dir_fd=root_fd, follow_symlinks=False), directory=True)
        snapshot = scan(root_fd, 0)

        def remove(fd, rows):
            for name, info, children in rows:
                if _identity(os.stat(name, dir_fd=fd, follow_symlinks=False)) != _identity(info):
                    raise StartupError('job_cleanup_failed')
                if children is None:
                    # Hard links are rejected as ambiguous ownership, not followed.
                    if info.st_nlink != 1:
                        raise StartupError('job_cleanup_failed')
                    os.unlink(name, dir_fd=fd)
                else:
                    child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                    try:
                        if _identity(os.fstat(child)) != _identity(info):
                            raise StartupError('job_cleanup_failed')
                        remove(child, children)
                    finally:
                        os.close(child)
                    if _identity(os.stat(name, dir_fd=fd, follow_symlinks=False)) != _identity(info):
                        raise StartupError('job_cleanup_failed')
                    os.rmdir(name, dir_fd=fd)
        remove(root_fd, snapshot)
        if _names(root_fd) or _identity(root.lstat()) != _identity(root_info):
            raise StartupError('job_cleanup_failed')
    except StartupError:
        raise
    except Exception:
        raise StartupError('job_cleanup_failed') from None
    finally:
        if root_fd is not None:
            os.close(root_fd)


def verify_installation():
    """Verify pinned dependency and artifact inventory before advertising readiness."""
    try:
        if (Path(__file__).resolve().parent != CODE_DIRECTORY
                or importlib.metadata.version('docling') != '2.139.0'
                or importlib.metadata.version('regex') != '2026.9.29'):
            raise StartupError('configuration_invalid')
        tools = CODE_DIRECTORY.parents[1] / 'tools' / 'docling'
        if not tools.is_dir():
            raise StartupError('configuration_invalid')
        sys.path.insert(0, str(tools))
        from extract_pdf import validate_artifacts
        validate_artifacts(str(ARTIFACTS_DIRECTORY))
    except StartupError:
        raise
    except Exception:
        raise StartupError('configuration_invalid') from None


async def serve():
    verify_installation()
    cleanup_orphan_jobs()
    processor = PDFProcessor(python_executable=PYTHON_EXECUTABLE, artifacts_directory=ARTIFACTS_DIRECTORY, temporary_root=JOB_ROOT)
    adapter = ContainerHTTPProcessor(processor)
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    registered = []
    try:
        for value in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(value, stop.set)
            registered.append(value)
        await adapter.start()
        await stop.wait()
    finally:
        try:
            await adapter.close()
        finally:
            for value in registered:
                loop.remove_signal_handler(value)


def main():
    try:
        asyncio.run(serve())
        return 0
    except (Exception, KeyboardInterrupt):
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
