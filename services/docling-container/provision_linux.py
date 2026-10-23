"""Explicit provisioning tool; run only in a disposable Linux amd64 Python 3.12.

Acquires public wheels during preparation, never during serving/build install.
Does not accept documents, credentials, model URLs or execute wheel code.
"""
import argparse
import email
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import zipfile


def run_pip(arguments):
    environment = {key: value for key, value in os.environ.items() if not key.startswith('PIP_')}
    environment['PIP_CONFIG_FILE'] = os.devnull
    subprocess.run([sys.executable, '-I', '-m', 'pip', *arguments], env=environment, check=True)


def wheel_inventory(directory):
    rows = []
    seen = set()
    for wheel in sorted(Path(directory).iterdir()):
        if not wheel.is_file() or wheel.suffix != '.whl':
            raise ValueError('unexpected_provisioning_file')
        with zipfile.ZipFile(wheel) as archive:
            names = [n for n in archive.namelist() if re.fullmatch(r'[^/]+\.dist-info/METADATA', n)]
            if len(names) != 1:
                raise ValueError('invalid_wheel_metadata')
            metadata = email.message_from_bytes(archive.read(names[0]))
        name, version = metadata['Name'], metadata['Version']
        if not name or not re.fullmatch(r'[A-Za-z0-9_.-]+', name) or not version or not re.fullmatch(r'[A-Za-z0-9_.+!-]+', version):
            raise ValueError('invalid_wheel_identity')
        canonical = re.sub(r'[-_.]+', '-', name).lower()
        if canonical in seen:
            raise ValueError('duplicate_wheel_identity')
        seen.add(canonical)
        with wheel.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        rows.append({'name': canonical, 'version': version, 'file': wheel.name,
                     'sha256': digest,
                     'license': str(metadata.get('License-Expression') or metadata.get('License') or 'UNKNOWN')})
    if not rows:
        raise ValueError('missing_wheels')
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    if sys.platform != 'linux' or platform.machine() != 'x86_64' or sys.version_info[:2] != (3, 12):
        parser.error('requires Linux x86_64 Python 3.12')
    root = args.destination.resolve()
    wheels = root / 'wheels'
    wheels.mkdir(parents=True, exist_ok=True)
    if any(wheels.iterdir()):
        parser.error('requires an empty wheel directory')
    # Resolve CPU packages only from the upstream PyTorch index, without deps.
    run_pip(['download', '--disable-pip-version-check', '--no-cache-dir',
                    '--only-binary=:all:', '--no-deps', '--index-url', 'https://download.pytorch.org/whl/cpu',
                    '--dest', str(wheels), 'torch==2.14.1+cpu', 'torchvision==0.29.1+cpu'])
    # All remaining dependencies come from PyPI. Local exact CPU versions cannot
    # be replaced by the larger CUDA variants during transitive resolution.
    run_pip(['download', '--disable-pip-version-check', '--no-cache-dir',
                    '--only-binary=:all:', '--index-url', 'https://pypi.org/simple', '--find-links', str(wheels),
                    '--dest', str(wheels), 'docling==2.139.0', 'regex==2026.9.29',
                    'torch==2.14.1+cpu', 'torchvision==0.29.1+cpu'])
    rows = wheel_inventory(wheels)
    (root / 'wheel-inventory.json').write_text(json.dumps({'platform': 'linux/amd64', 'python': '3.12',
                                                         'packages': rows}, indent=2) + '\n')
    (root / 'requirements-linux.lock.txt').write_text('\n'.join(
        f"{r['name']}=={r['version']} --hash=sha256:{r['sha256']}" for r in rows) + '\n')
    print(json.dumps({'wheels': len(rows), 'platform': 'linux/amd64'}))


if __name__ == '__main__':
    main()
