#!/usr/bin/env python3
"""Local-only scanning. Never persist raw scanner reports or print tool output."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
from swift_scan import scan as scan_swift

ROOT = Path(__file__).resolve().parents[2]
VERSIONS = {"semgrep": "1.179.0", "gitleaks": "8.24.3"}
# Keep this list synchronized with the four structural rules in swift_scan.swift.
NATIVE_SWIFT_RULES = frozenset({
    "studiquo.swift.userdefaults-credential",
    "studiquo.swift.trust-all-challenge",
    "studiquo.swift.credential-log",
    "studiquo.swift.weak-hash",
})


def execute(args, cwd=ROOT):
    env = dict(os.environ, SEMGREP_SEND_METRICS="off", SEMGREP_ENABLE_VERSION_CHECK="0")
    env.pop("SEMGREP_APP_TOKEN", None)
    return subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True, timeout=600)


def field(value):
    # Strip control characters; reports must not carry scanner messages or code.
    return "".join(c for c in str(value) if c.isprintable())[:500]


def semgrep_report(data):
    if data.get("errors") or data.get("skipped_rules"):
        raise RuntimeError("Semgrep reported errors or skipped rules")
    scanned = data.get("paths", {}).get("scanned", [])
    if not scanned or not any(p.endswith(".swift") for p in scanned) or not any(p.endswith(".js") for p in scanned):
        raise RuntimeError("Semgrep did not scan both Swift and JavaScript files")
    findings = []
    for item in data["results"]:
        findings.append({"tool": "semgrep", "rule": field(item["check_id"]),
                         "path": field(item["path"]), "line": item["start"]["line"],
                         "severity": item["extra"]["severity"]})
    return findings, len(scanned)


def secret_report(data):
    if not isinstance(data, list):
        raise RuntimeError("Invalid Gitleaks report")
    # Do not retain Match, Secret, author, email, commit message, or fingerprint.
    return [{"tool": "gitleaks", "rule": field(i["RuleID"]), "path": field(i["File"]),
             "line": i["StartLine"], "severity": "ERROR"} for i in data]


def audit_report(data, production_names=None):
    if "error" in data or "vulnerabilities" not in data or not data.get("metadata", {}).get("dependencies", {}).get("total"):
        raise RuntimeError("npm audit failed or checked zero dependencies")
    findings = []
    for name, item in data["vulnerabilities"].items():
        advisories = [{"url": advisory["url"], "severity": advisory["severity"]}
                      for advisory in item.get("via", [])
                      if isinstance(advisory, dict)
                      and str(advisory.get("url", "")).startswith("https://github.com/advisories/")]
        development_only = production_names is not None and name not in production_names
        findings.append({"tool": "npm-audit", "rule": field(name),
                         "path": "mcp-server/package-lock.json", "line": 1,
                         "risk": item["severity"], "advisories": advisories,
                         "dependency_scope": "development-only" if development_only else "production-or-mixed",
                         "severity": {"critical": "ERROR", "high": "ERROR", "moderate": "WARNING"}.get(item["severity"], "INFO")})
    return findings




def merge_code_findings(semgrep_findings, native_findings):
    """Remove only actual duplicates of the four native-supported Swift rules."""
    def key(item):
        rule = item['rule']
        marker = 'studiquo.swift.'
        if marker in rule:
            rule = marker + rule.rsplit(marker, 1)[1]
        return rule, item['path'], item['line']
    native_keys = {key(item) for item in native_findings if item['rule'] in NATIVE_SWIFT_RULES}
    retained = [item for item in semgrep_findings
                if not (item['path'].endswith('.swift') and key(item) in native_keys)]
    return retained + native_findings

def resolve_parser_gaps(errors, swift_report, source_hashes):
    """Resolve only known CE partial parsing with complete same-content native coverage."""
    coverage = {item['path']: item for item in swift_report['coverage']}
    resolved, unresolved = [], []
    for error in errors:
        kind = error.get('type', 'unknown')
        if isinstance(kind, list):
            kind = kind[0]
        path = error.get('path', 'unknown')
        file = coverage.get(path)
        if (kind == 'PartialParsing' and file and file['sha256'] == source_hashes.get(path)
                and file['parsedBytes'] == file['sourceBytes']):
            resolved.append({'path': path, 'semgrep_error': kind,
                             'resolved_by': 'swift-syntax', 'sha256': file['sha256']})
        else:
            unresolved.append(f'Semgrep {field(kind)}: {field(path)}')
    return resolved, unresolved

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=ROOT / "security-reports" / "sast")
    parser.add_argument("--enforce", choices=["ERROR", "WARNING", "INFO"])
    parser.add_argument("--skip-audit", action="store_true", help="Explicitly omit dependency audit (offline use)")
    args = parser.parse_args()
    report = {"status": "error", "mode": "enforce" if args.enforce else "report-only",
              "versions": dict(VERSIONS), "scanned_files": 0, "findings": [], "errors": [],
              "limitations": ["Swift rules use full-fidelity syntax trees; no interprocedural dataflow or type checking.",
                              "CodeQL pending GitHub eligibility and macOS build configuration.",
                              "Working-tree secret detection covers tracked and non-ignored regular files.",
                              "Swift SDK dependencies are not covered by npm audit."]}
    if args.skip_audit:
        report["limitations"].append("npm audit explicitly skipped.")
    try:
        for tool, version in VERSIONS.items():
            result = execute([tool, "--version" if tool == "semgrep" else "version"])
            if result.returncode or result.stdout.strip() != version:
                raise RuntimeError(f"{tool} missing or version differs from {version}")
        shallow = execute(["git", "rev-parse", "--is-shallow-repository"])
        if shallow.returncode or shallow.stdout.strip() != "false":
            raise RuntimeError("Full Git history is required for Gitleaks")
        # TemporaryDirectory uses owner-only permissions. Raw reports are never artifacts.
        with tempfile.TemporaryDirectory(prefix="studiquo-sast-") as directory:
            temporary = Path(directory)
            manifest = execute(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"])
            if manifest.returncode or not manifest.stdout:
                raise RuntimeError("Unable to enumerate source files")
            swift_files = sorted({path for path in manifest.stdout.split("\0")
                                  if path.endswith(".swift") and not path.startswith("security/sast/fixtures/")
                                  and (ROOT / path).is_file() and not (ROOT / path).is_symlink()})
            original_hashes = {path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest() for path in swift_files}
            raw = temporary / "semgrep.json"
            result = execute(["semgrep", "scan", "--config", ".semgrep.yml", "--metrics", "off",
                              "--disable-version-check", "--strict", "--json", "--output", str(raw), "."])
            if result.returncode not in (0, 3) or not raw.exists():
                raise RuntimeError("Semgrep execution failed (raw output withheld)")
            semgrep_data = json.loads(raw.read_text())
            native = scan_swift(swift_files, cwd=ROOT)
            if {item['path']: item['sha256'] for item in native['coverage']} != original_hashes:
                raise RuntimeError("Swift source changed between scanner executions")
            report["versions"]["swift-compiler"] = native["compiler"]
            report["swift_coverage"] = native["coverage"]
            resolved, unresolved = resolve_parser_gaps(semgrep_data.get("errors", []), native, original_hashes)
            report["resolved_parser_gaps"] = resolved
            report["errors"].extend(unresolved)
            if result.returncode and not semgrep_data.get("errors"):
                raise RuntimeError("Semgrep returned an error without diagnostics")
            # Keep partial findings, but the overall scan remains failed.
            findings, count = semgrep_report(dict(semgrep_data, errors=[]))
            # Preserve unsupported/new CE rules and unmatched findings.
            report["findings"].extend(merge_code_findings(findings, native["findings"]))
            report["scanned_files"] = len(set(semgrep_data["paths"]["scanned"]) | set(swift_files))
            snapshot = temporary / "working-tree"
            snapshot.mkdir()
            tracked = execute(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"])
            if tracked.returncode or not tracked.stdout:
                raise RuntimeError("Unable to enumerate tracked files")
            for name in tracked.stdout.split("\0"):
                if not name:
                    continue
                source = ROOT / name
                if source.is_symlink():
                    continue
                if source.is_file():
                    target = snapshot / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(source, target)
            for mode in ("git", "dir"):
                raw = temporary / f"gitleaks-{mode}.json"
                command = ["gitleaks", mode, "." if mode == "git" else str(snapshot), "--config", ".gitleaks.toml", "--redact=100",
                           "--report-format", "json", "--report-path", str(raw), "--exit-code", "10", "--no-banner"]
                if mode == "git":
                    command += ["--log-opts=--all"]
                result = execute(command)
                if result.returncode not in (0, 10) or not raw.exists():
                    raise RuntimeError(f"Gitleaks {mode} execution failed (raw output withheld)")
                secrets = secret_report(json.loads(raw.read_text()))
                for finding in secrets:
                    finding["scope"] = "full-git-history" if mode == "git" else "working-tree"
                    if mode == "dir":
                        finding["path"] = finding["path"].removeprefix(str(snapshot) + "/")
                report["findings"].extend(secrets)
            if not args.skip_audit:
                result = execute(["npm", "audit", "--package-lock-only", "--json"], cwd=ROOT / "mcp-server")
                if result.returncode not in (0, 1):
                    raise RuntimeError("npm audit execution failed (raw output withheld)")
                all_audit = json.loads(result.stdout)
                production = execute(["npm", "audit", "--package-lock-only", "--omit=dev", "--json"], cwd=ROOT / "mcp-server")
                if production.returncode not in (0, 1):
                    raise RuntimeError("Production npm audit execution failed")
                production_data = json.loads(production.stdout)
                audit_report(production_data)
                report["findings"].extend(audit_report(all_audit, set(production_data["vulnerabilities"])))
        unique = {json.dumps(item, sort_keys=True): item for item in report["findings"]}
        report["findings"] = list(unique.values())
        report["status"] = "error" if report["errors"] else "complete"
    except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired, RuntimeError) as error:
        # Scanner-controlled exceptions can contain source content: allow only own messages.
        report["errors"].append(str(error) if isinstance(error, RuntimeError) else "Scanner output invalid or tool unavailable")
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "summary.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    lines = ["# SAST 検査結果", "", f"Status: {report['status']}", f"Scanned files: {report['scanned_files']}",
             f"Findings: {len(report['findings'])}", "", "| Tool | Rule | File | Line | Severity | Risk | Scope |", "|---|---|---|---|---|---|---|"]
    def markdown(value):
        return field(value).replace("|", "\\|").replace("<", "&lt;").replace(">", "&gt;")
    for item in report["findings"]:
        values = [item[key] for key in ("tool", "rule", "path", "line", "severity")]
        values += [item.get("risk", ""), item.get("dependency_scope", item.get("scope", ""))]
        lines.append("| " + " | ".join(markdown(value) for value in values) + " |")
    if report.get("swift_coverage"):
        total_bytes = sum(item["sourceBytes"] for item in report["swift_coverage"])
        lines += ["", "## Swift syntax coverage", "",
                  f"{len(report['swift_coverage'])} files, {total_bytes} source bytes fully parsed and SHA-256 verified.",
                  markdown(report["versions"]["swift-compiler"])]
        for gap in report.get("resolved_parser_gaps", []):
            lines.append(f"- CE PartialParsing completed by full Swift AST: {markdown(gap['path'])}")
    lines += ["", "## Limitations", ""] + [f"- {item}" for item in report["limitations"]]
    lines += ["", "## Errors", ""] + [f"- {item}" for item in report["errors"]]
    (args.output / "summary.md").write_text("\n".join(lines) + "\n")
    print(f"SAST {report['status']}: {len(report['findings'])} findings; sanitized report written.")
    if report["status"] != "complete":
        return 2
    levels = {"ERROR": 3, "WARNING": 2, "INFO": 1}
    if args.enforce and any(levels.get(i["severity"], 3) >= levels[args.enforce] for i in report["findings"]):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
