import unittest
import json
import hashlib
from pathlib import Path
import subprocess
import tempfile
from unittest.mock import patch
import run
from run import semgrep_report, secret_report, audit_report


class ReportsTest(unittest.TestCase):
    def test_semgrep_rejects_empty_or_partial_coverage(self):
        for paths in ([], ['app.swift'], ['server.js']):
            with self.assertRaises(RuntimeError):
                semgrep_report({'results': [], 'paths': {'scanned': paths}})

    def test_semgrep_rejects_parser_error(self):
        with self.assertRaises(RuntimeError):
            semgrep_report({'errors': [{'type': 'ParseError'}]})

    def test_secret_report_has_no_source_or_personal_data(self):
        result = secret_report([{'RuleID': 'fixture', 'File': 'file', 'StartLine': 1,
                                'Secret': 'artificial', 'Match': 'artificial', 'Author': 'private',
                                'Email': 'private', 'Message': 'private'}])
        self.assertEqual(set(result[0]), {'tool', 'rule', 'path', 'line', 'severity'})
        self.assertNotIn('private', str(result))
        self.assertNotIn('artificial', str(result))

    def test_audit_rejects_error_and_zero_dependencies(self):
        for data in ({'error': {}}, {'vulnerabilities': {}, 'metadata': {'dependencies': {'total': 0}}}):
            with self.assertRaises(RuntimeError):
                audit_report(data)


class FindingMergeTest(unittest.TestCase):
    def test_new_swift_rule_and_unmatched_existing_findings_are_preserved(self):
        native = [{'tool': 'swift-syntax', 'rule': 'studiquo.swift.credential-log',
                   'path': 'app.swift', 'line': 10, 'severity': 'WARNING'}]
        duplicate = dict(native[0], tool='semgrep')
        new_rule = dict(duplicate, rule='studiquo.swift.future-rule')
        unmatched = dict(duplicate, line=20)
        javascript = dict(duplicate, path='server.js')
        result = run.merge_code_findings([duplicate, new_rule, unmatched, javascript], native)
        self.assertEqual(result, [new_rule, unmatched, javascript, *native])

    def test_semgrep_rule_prefix_and_exact_match_preserve_canonical_native_result(self):
        native = [{'tool': 'swift-syntax', 'rule': 'studiquo.swift.weak-hash',
                   'path': 'app.swift', 'line': 8, 'severity': 'WARNING'}]
        duplicate = dict(native[0], tool='semgrep', rule='prefix.studiquo.swift.weak-hash')
        self.assertEqual(run.merge_code_findings([duplicate], native), native)


class ParserResolutionTest(unittest.TestCase):
    def test_only_same_source_full_coverage_resolves_partial_parsing(self):
        native = {'coverage': [{'path': 'file.swift', 'sha256': 'same', 'sourceBytes': 30, 'parsedBytes': 30}]}
        resolved, errors = run.resolve_parser_gaps([{'type': ['PartialParsing', []], 'path': 'file.swift'}], native, {'file.swift': 'same'})
        self.assertEqual(len(resolved), 1)
        self.assertEqual(errors, [])

    def test_unknown_syntax_missing_coverage_and_changed_source_remain_errors(self):
        complete = {'coverage': [{'path': 'file.swift', 'sha256': 'same', 'sourceBytes': 30, 'parsedBytes': 30}]}
        scenarios = [({'type': 'Syntax error', 'path': 'file.swift'}, complete, {'file.swift': 'same'}),
                     ({'type': 'Unknown parser error', 'path': 'file.swift'}, complete, {'file.swift': 'same'}),
                     ({'type': 'PartialParsing', 'path': 'missing.swift'}, complete, {'file.swift': 'same'}),
                     ({'type': 'PartialParsing', 'path': 'file.swift'}, complete, {'file.swift': 'changed'}),
                     ({'type': 'PartialParsing', 'path': 'file.swift'},
                      {'coverage': [{'path': 'file.swift', 'sha256': 'same', 'sourceBytes': 30, 'parsedBytes': 20}]},
                      {'file.swift': 'same'})]
        for error, native, fingerprints in scenarios:
            resolved, errors = run.resolve_parser_gaps([error], native, fingerprints)
            self.assertEqual(resolved, [])
            self.assertEqual(len(errors), 1)


class RunnerContractTest(unittest.TestCase):
    def simulate(self, parser_error=False, enforce=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'app.swift').write_text('// fixture')
            output = root / 'reports'
            commands = []
            def execute(command, cwd=None):
                commands.append(command)
                text = ''
                code = 0
                if command[0] == 'semgrep' and '--version' in command:
                    text = run.VERSIONS['semgrep']
                elif command[:2] == ['gitleaks', 'version']:
                    text = run.VERSIONS['gitleaks']
                elif command[:2] == ['git', 'rev-parse']:
                    text = 'false'
                elif command[:2] == ['git', 'ls-files']:
                    text = 'app.swift\0'
                elif command[:2] == ['semgrep', 'scan']:
                    code = 3 if parser_error else 0
                    report = {'results': [{'check_id': 'studiquo.swift.credential-log', 'path': 'app.swift',
                                          'start': {'line': 1}, 'extra': {'severity': 'ERROR', 'lines': 'withheld fixture'}}],
                              'paths': {'scanned': ['app.swift', 'server.js']},
                              'errors': [{'type': 'Syntax error', 'path': 'app.swift', 'message': 'withheld fixture'}] if parser_error else []}
                    Path(command[command.index('--output') + 1]).write_text(json.dumps(report))
                elif command[0] == 'gitleaks':
                    Path(command[command.index('--report-path') + 1]).write_text('[]')
                elif command[0] == 'npm':
                    text = json.dumps({'vulnerabilities': {}, 'metadata': {'dependencies': {'total': 1}}})
                else:
                    raise AssertionError(command)
                return subprocess.CompletedProcess(command, code, text, '')
            arguments = ['run.py', '--output', str(output)] + (['--enforce', 'ERROR'] if enforce else [])
            native = {'coverage': [{'path': 'app.swift', 'sha256': hashlib.sha256(b'// fixture').hexdigest(),
                                    'sourceBytes': 10, 'parsedBytes': 10, 'tokens': 1, 'calls': 0}],
                      'findings': [{'tool': 'swift-syntax', 'rule': 'studiquo.swift.credential-log', 'path': 'app.swift', 'line': 1, 'severity': 'ERROR'}],
                      'compiler': 'fixture compiler'}
            with patch.object(run, 'ROOT', root), patch.object(run, 'execute', execute), patch('sys.argv', arguments), patch.object(run, 'scan_swift', return_value=native):
                result = run.main()
            report = json.loads((output / 'summary.json').read_text())
            self.assertNotIn('withheld fixture', str(report))
            return result, report, commands

    def test_parser_errors_preserve_partial_findings_and_run_other_scanners(self):
        code, report, commands = self.simulate(parser_error=True)
        self.assertEqual(code, 2)
        self.assertEqual(report['status'], 'error')
        self.assertEqual(len(report['findings']), 1)
        self.assertEqual(sum(c[0] == 'npm' for c in commands), 2)
        self.assertTrue(any(c[:2] == ['gitleaks', 'git'] for c in commands))

    def test_report_only_and_enforcement_exit_codes(self):
        self.assertEqual(self.simulate()[0], 0)
        self.assertEqual(self.simulate(enforce=True)[0], 1)


if __name__ == '__main__':
    unittest.main()
