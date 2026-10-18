// 取得処理: タイムアウト・再試行・ディスクキャッシュ・間隔制御。
// テストでは fetchImpl を差し替える。

import { mkdirSync, readFileSync, writeFileSync, existsSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';

export function createClient({ cacheDir = null, ttlMs = 6 * 3600_000, offline = false, fetchImpl = globalThis.fetch, sleep = (ms) => new Promise((r) => setTimeout(r, ms)) } = {}) {
  const lastAt = new Map();

  async function throttle(host, minGapMs) {
    const wait = (lastAt.get(host) ?? 0) + minGapMs - Date.now();
    if (wait > 0) await sleep(wait);
    lastAt.set(host, Date.now());
  }

  function cachePath(url, body) {
    return `${cacheDir}/${createHash('sha256').update(url + (body ?? '')).digest('hex')}.json`;
  }

  /** JSONを返す。キャッシュが新しければネットワークに行かない。offline ならキャッシュのみ(古くても使う)。 */
  async function json(url, { method = 'GET', body = null, headers = {}, minGapMs = 0, retries = 3 } = {}) {
    const file = cacheDir ? cachePath(url, body) : null;
    if (file && existsSync(file) && (offline || Date.now() - statSync(file).mtimeMs < ttlMs)) {
      return JSON.parse(readFileSync(file, 'utf8'));
    }
    if (offline) throw new Error(`オフラインでキャッシュが無い: ${url}`);

    const host = new URL(url).host;
    let lastErr;
    for (let attempt = 0; attempt <= retries; attempt++) {
      try {
        if (minGapMs) await throttle(host, minGapMs);
        const res = await fetchImpl(url, {
          method,
          body,
          headers: { 'user-agent': 'studiquo-vuln-watch', ...(body ? { 'content-type': 'application/json' } : {}), ...headers },
          signal: AbortSignal.timeout(30_000),
        });
        if (res.status === 429 || res.status >= 500 || res.status === 403) {
          lastErr = new Error(`HTTP ${res.status}: ${host}`);
          await sleep(2000 * 2 ** attempt);
          continue;
        }
        if (!res.ok) throw new Error(`HTTP ${res.status}: ${url}`);
        const data = await res.json();
        if (file) {
          mkdirSync(cacheDir, { recursive: true });
          writeFileSync(file, JSON.stringify(data));
        }
        return data;
      } catch (e) {
        lastErr = e;
        if (/^HTTP 4/.test(e.message)) throw e;
        await sleep(2000 * 2 ** attempt);
      }
    }
    throw lastErr;
  }

  return { json };
}
