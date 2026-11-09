import { realpathSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, resolve, sep } from 'node:path';

/**
 * Where `--out` may point. The scan writes (and clears) files there, so an unattended run given a
 * wrong or injected path must not be able to reach the rest of the disk: only the tool's own `out/`
 * directory and the system temporary directories are accepted.
 */
export function allowedOutRoots(toolDir: string): string[] {
  return [resolve(toolDir, 'out'), tmpdir(), '/tmp', '/private/tmp'].map(root => realOrSelf(root));
}

/** The resolved output directory, or null when it lies outside the allowed roots. */
export function checkedOutDir(requested: string, toolDir: string): string | null {
  const target = realOrSelf(resolve(requested));
  return allowedOutRoots(toolDir).some(root => target === root || target.startsWith(root + sep)) ? target : null;
}

// A path that does not exist yet is judged by its nearest existing parent, so a symlink on the way
// cannot lead out of an allowed root.
function realOrSelf(path: string): string {
  let current = resolve(path);
  const rest: string[] = [];
  for (;;) {
    try {
      return resolve(realpathSync(current), ...rest.reverse());
    } catch {
      const parent = dirname(current);
      if (parent === current) return resolve(path);
      rest.push(current.slice(parent.length + 1));
      current = parent;
    }
  }
}
