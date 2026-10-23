import unittest
from types import SimpleNamespace
from scan_proof import collect_proof


class ProofTests(unittest.TestCase):
    def sdk(self, progress='100', pending='0', ids=None):
        return SimpleNamespace(
            ascan=SimpleNamespace(
                scans=[{'id': '1'}], status=lambda _: progress,
                messages_ids=lambda _: ['10', '11'] if ids is None else ids,
                scanners=lambda **_: [{'enabled': 'true', 'alertThreshold': 'MEDIUM'}, {'enabled': 'true', 'alertThreshold': 'OFF'}]),
            pscan=SimpleNamespace(scanners=[{'enabled': True}], records_to_scan=pending))

    def test_counts_only(self):
        proof = collect_proof(self.sdk())
        self.assertEqual(proof, {'activeScanCount': 1, 'activeProgress': [100], 'activeMessageCount': 2, 'enabledActiveRules': 1, 'enabledPassiveRules': 1, 'passivePending': 0})
        self.assertNotIn('id', proof)

    def test_incomplete_scan_and_queue_are_visible(self):
        proof = collect_proof(self.sdk(progress='50', pending='5'))
        self.assertEqual(proof['activeProgress'], [50])
        self.assertEqual(proof['passivePending'], 5)

    def test_invalid_counters_fail(self):
        for sdk in [self.sdk(progress='secret'), self.sdk(pending=-1), self.sdk(ids='not-a-list')]:
            with self.assertRaises(ValueError):
                collect_proof(sdk)


if __name__ == '__main__':
    unittest.main()
