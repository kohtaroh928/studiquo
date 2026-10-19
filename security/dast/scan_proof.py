"""Packaged API-scan hook: export counts only, never message IDs or URLs."""
import json
import re


def nonnegative_integer(value):
    if isinstance(value, bool) or not re.fullmatch(r'[0-9]+', str(value)):
        raise ValueError('Invalid scanner counter')
    return int(value)


def enabled_count(rules):
    if not isinstance(rules, list):
        raise ValueError('Invalid scanner rules')
    return sum(1 for rule in rules if rule.get('enabled') in (True, 'true') and rule.get('alertThreshold') != 'OFF')


def collect_proof(zap):
    scans = zap.ascan.scans
    if not isinstance(scans, list):
        raise ValueError('Invalid active scans')
    progress = []
    messages = set()
    for scan in scans:
        scan_id = str(nonnegative_integer(scan['id']))
        progress.append(nonnegative_integer(zap.ascan.status(scan_id)))
        ids = zap.ascan.messages_ids(scan_id)
        if not isinstance(ids, list):
            raise ValueError('Invalid active message count')
        messages.update(nonnegative_integer(message_id) for message_id in ids)
    return {
        'activeScanCount': len(scans),
        'activeProgress': progress,
        'activeMessageCount': len(messages),
        'enabledActiveRules': enabled_count(zap.ascan.scanners(scanpolicyname='API-Minimal')),
        'enabledPassiveRules': enabled_count(zap.pscan.scanners),
        'passivePending': nonnegative_integer(zap.pscan.records_to_scan),
    }


def zap_pre_shutdown(zap):
    proof = collect_proof(zap)
    with open('/zap/wrk/scan-proof.json', 'w') as output:
        json.dump(proof, output)
