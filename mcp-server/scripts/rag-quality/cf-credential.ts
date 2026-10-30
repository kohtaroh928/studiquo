// Cloudflare credential for the paid RAG evaluations.
//
// The default is a dedicated API token (Workers AI only, one per person, long-lived; see
// docs/RUNBOOK.md A-5). The Wrangler OAuth login on a developer machine can deploy Workers and
// write D1, so it is used only when STUDIQUO_ALLOW_WRANGLER_OAUTH=true is set on purpose.
// Neither value is ever logged or returned in an error message.
import { readFileSync } from "node:fs";
import { homedir } from "node:os";

export type Env = Record<string, string | undefined>;

export function cloudflareToken(env: Env = process.env, readAuthFile: (path: string) => string = (p) => readFileSync(p, "utf8")): string {
  const dedicated = env.CLOUDFLARE_API_TOKEN?.trim();
  if (dedicated) return dedicated;
  if (env.STUDIQUO_ALLOW_WRANGLER_OAUTH !== "true") throw new Error("dedicated_cloudflare_token_required");
  let text: string;
  try {
    text = readAuthFile(env.STUDIQUO_CF_AUTH_FILE ?? `${homedir()}/.wrangler/config/default.toml`);
  } catch {
    throw new Error("cloudflare_auth_unavailable");
  }
  const oauth = text.match(/^oauth_token\s*=\s*"([^"]+)"/m)?.[1];
  if (!oauth) throw new Error("cloudflare_auth_unavailable");
  return oauth;
}
