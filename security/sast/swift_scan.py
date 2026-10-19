"""Compile against the active Swift toolchain's full-fidelity parser, then scan."""
import json
import hashlib
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def scan(files, cwd=ROOT):
    if not files:
        raise RuntimeError('Swift syntax scan requires at least one file')
    compiler = subprocess.run(['xcrun', '--find', 'swiftc'], capture_output=True, text=True, timeout=30)
    if compiler.returncode:
        raise RuntimeError('Swift compiler unavailable; full Swift coverage is required')
    executable = Path(compiler.stdout.strip())
    host = executable.parent.parent / 'lib/swift/host'
    version = subprocess.run([str(executable), '--version'], capture_output=True, text=True, timeout=30)
    if version.returncode or not (host / 'SwiftParser.swiftmodule').exists():
        raise RuntimeError('SwiftParser from the active compiler toolchain is unavailable')
    with tempfile.TemporaryDirectory(prefix='studiquo-swift-sast-') as directory:
        binary = Path(directory) / 'swift-sast'
        build = subprocess.run(['xcrun', 'swiftc', '-I', str(host), '-L', str(host),
                                '-module-cache-path', str(Path(directory) / 'modules'),
                                '-lSwiftParser', '-lSwiftSyntax', '-Xlinker', '-rpath', '-Xlinker', str(host),
                                str(ROOT / 'security/sast/swift_scan.swift'), '-o', str(binary)],
                               capture_output=True, text=True, timeout=180)
        if build.returncode:
            raise RuntimeError('Swift syntax checker compilation failed (diagnostics withheld)')
        process = subprocess.run([str(binary), *files], cwd=cwd, capture_output=True, text=True, timeout=180)
        if process.returncode not in (0, 2):
            raise RuntimeError('Swift syntax checker execution failed')
        data = json.loads(process.stdout)
        coverage = data.get('coverage', [])
        if data.get('errors') or process.returncode or {item['path'] for item in coverage} != set(files):
            raise RuntimeError('Swift syntax checker has parsing errors or incomplete file coverage')
        for item in coverage:
            if any(type(item.get(key)) is not int or item[key] < 0
                   for key in ('sourceBytes', 'parsedBytes', 'tokens', 'calls')):
                raise RuntimeError('Swift syntax checker returned invalid coverage counts')
            actual = (Path(cwd) / item['path']).read_bytes()
            if (item['sourceBytes'] != len(actual) or item['parsedBytes'] != len(actual)
                    or not item['tokens'] or item.get('sha256') != hashlib.sha256(actual).hexdigest()):
                raise RuntimeError('Swift syntax checker did not parse the complete unchanged source')
        data['compiler'] = version.stdout.splitlines()[0]
        return data
