import hashlib
from pathlib import Path
import tempfile
import unittest
from swift_scan import scan


class NativeSwiftRulesTest(unittest.TestCase):
    def test_existing_swift_rule_fixtures_have_equivalent_findings(self):
        path = 'security/sast/fixtures/swift.swift'
        result = scan([path])
        self.assertEqual({(i['rule'].rsplit('.', 1)[-1], i['line']) for i in result['findings']},
                         {('userdefaults-credential', 4), ('trust-all-challenge', 8),
                          ('credential-log', 14), ('weak-hash', 18)})

    def test_multiline_calls_all_branches_and_complete_unicode_file(self):
        source = '''// 日本語の先頭コメント、偽の print(password) は検出しない。
let pattern = /^[A-Z0-9]{6,32}$/
func test(value: String, token: String, data: Data, trust: SecTrust) {
    let comparison = [1, 2].max {
        $0
            < $1
    }
    let predicate = #Predicate { $0.sourceTitle == value }
    switch value { case "fixture": break; default: break }
    UserDefaults.standard.set(
        value,
        forKey: "accessToken"
    )
    print(
        token
    )
    Insecure.MD5.hash(
        data: data
    )
    let fixture = URLCredential(
        trust: trust
    )
    // Safe calls and literal strings cannot create fake call-expression findings.
    let text = "print(password); URLCredential(trust: trust)"
    print(value)
    UserDefaults.standard.set(value, forKey: "theme")
    SHA256.hash(data: data)
    CustomURLCredential(trust: trust)
}
#if false
func inactive(token: String) {
    debugPrint(
        token
    )
}
#endif
func tail(data: Data) {
    Insecure.SHA1.hash(data: data)
}
'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixture.swift'
            path.write_text(source)
            result = scan([str(path)])
        found = [(i['rule'].rsplit('.', 1)[-1], i['line']) for i in result['findings']]
        self.assertEqual(found, [('userdefaults-credential', 10), ('credential-log', 14),
                                 ('weak-hash', 17), ('trust-all-challenge', 20),
                                 ('credential-log', 32), ('weak-hash', 38)])
        coverage = result['coverage'][0]
        self.assertEqual(coverage['sourceBytes'], len(source.encode()))
        self.assertEqual(coverage['parsedBytes'], len(source.encode()))
        self.assertEqual(coverage['sha256'], hashlib.sha256(source.encode()).hexdigest())
        self.assertGreater(coverage['calls'], len(found))

    def test_invalid_source_and_empty_scope_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'invalid.swift'
            path.write_text('func invalid( { print(token)')
            with self.assertRaises(RuntimeError):
                scan([str(path)])
        with self.assertRaises(RuntimeError):
            scan([])


if __name__ == '__main__':
    unittest.main()
