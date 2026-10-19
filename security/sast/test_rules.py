#!/usr/bin/env python3
"""Verify positive/negative rule annotations using the real Semgrep engine."""
import json
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile

def main():
    root = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory(prefix='studiquo-rule-tests-') as directory:
        target = Path(directory)
        expected, forbidden = set(), set()
        for source in (root / 'security/sast/fixtures').iterdir():
            shutil.copyfile(source, target / source.name)
            for number, line in enumerate(source.read_text().splitlines(), 1):
                annotation = re.search(r'// (ruleid|ok): (\S+)', line)
                if annotation:
                    entry = (annotation[2], source.name, number + 1)
                    (expected if annotation[1] == 'ruleid' else forbidden).add(entry)
        env = dict(os.environ, SEMGREP_SEND_METRICS='off', SEMGREP_ENABLE_VERSION_CHECK='0')
        env.pop('SEMGREP_APP_TOKEN', None)
        result = subprocess.run(['semgrep', 'scan', '--config', str(root / '.semgrep.yml'),
                                 '--json', '--strict', '--metrics', 'off', '--disable-version-check',
                                 '--no-git-ignore', '.'], env=env, cwd=target, capture_output=True, text=True)
        if result.returncode:
            print('Rule fixture scan failed (tool output withheld).')
            raise SystemExit(2)
        data = json.loads(result.stdout)
        if data.get('errors') or data.get('skipped_rules') or len(data.get('paths', {}).get('scanned', [])) != 2:
            print('Rule fixture scan has errors or incomplete coverage.')
            raise SystemExit(2)
        actual = {(i['check_id'].rsplit('studiquo.', 1)[-1], Path(i['path']).name, i['start']['line']) for i in data['results']}
        expected = {(rule.removeprefix('studiquo.'), path, line) for rule, path, line in expected}
        forbidden = {(rule.removeprefix('studiquo.'), path, line) for rule, path, line in forbidden}
        missing, unexpected = expected - actual, actual - expected
        if missing or unexpected or actual & forbidden:
            print(f'Missing fixture findings: {sorted(missing)}; unexpected: {sorted(unexpected)}')
            raise SystemExit(1)
        print(f'Rules verified: {len(expected)} positive and {len(forbidden)} negative fixtures.')


if __name__ == "__main__":
    main()
