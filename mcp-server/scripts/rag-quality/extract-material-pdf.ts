// Compile the exact app extraction policy; keep document output private in Swift.
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
const args = process.argv.slice(2);
if (args.length !== 2) { process.stderr.write('Specify a PDF and a new private output file.\n'); process.exit(1); }
const root = mkdtempSync(join(tmpdir(), 'studiquo-rag-extract-'));
try {
 const source = fileURLToPath(new URL('../../../studiquo/Services/RAGDocumentTextExtractionService.swift', import.meta.url) as any);
 const main = join(root, 'main.swift'); const binary = join(root, 'extract');
 writeFileSync(main, readFileSync(new URL('./extract-material-pdf.swift', import.meta.url) as any), { mode: 0o600 });
 const build = spawnSync('swiftc', ['-module-cache-path', join(root, 'cache'), source, main, '-o', binary], { encoding: 'utf8' });
 if (build.status !== 0) throw Error('compile_failed');
 const run = spawnSync(binary, args, { stdio: 'inherit' });
 process.exitCode = run.status ?? 1;
} catch { process.stderr.write('PDF extraction unavailable. No document details logged.\n'); process.exitCode = 1; }
finally { rmSync(root, { recursive: true, force: true }); }
