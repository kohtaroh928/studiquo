// Checks the evaluation token WITHOUT spending Workers AI usage and without printing the value.
//   CLOUDFLARE_ACCOUNT_ID=<id> CLOUDFLARE_API_TOKEN=<token> node scripts/rag-quality/check-cf-token.ts
// Prints: whether Cloudflare accepts the token and when it expires (if it does); see docs/RUNBOOK.md A-5.
// The verify endpoint reports status and expiry only; it cannot list permissions. Confirm "Workers AI
// only" on the token's page in the Cloudflare dashboard.
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

export type Verdict = { ok: boolean; lines: string[] };

export function judge(result: { status?: string; expires_on?: string } | null, now = Date.now()): Verdict {
  const lines: string[] = [];
  if (!result || result.status !== "active") return { ok: false, lines: ["NG  Cloudflare does not accept this token as active."] };
  lines.push("OK  Cloudflare accepts the token (active).");
  let ok = true;
  // No expiry is allowed (docs/RUNBOOK.md A-5): the token is long-lived by choice, so the other
  // limits (one person, Workers AI only, revoke on leak, yearly rotation) carry the safety.
  if (!result.expires_on) lines.push("--  No expiry (allowed). Rotate it yearly and revoke it if it may have leaked.");
  else {
    const days = (Date.parse(result.expires_on) - now) / 86_400_000;
    if (!(days > 0)) {
      ok = false;
      lines.push("NG  The token has already expired.");
    } else lines.push(`OK  Expires in ${Math.ceil(days)} day(s).`);
  }
  lines.push("--  Permissions are not visible here. Confirm Workers AI is the only permission in the dashboard.");
  return { ok, lines };
}

export async function main(env = process.env, fetcher: typeof fetch = fetch): Promise<number> {
  const account = env.CLOUDFLARE_ACCOUNT_ID;
  const token = env.CLOUDFLARE_API_TOKEN?.trim();
  if (!account || !token) {
    process.stderr.write("CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN are required.\n");
    return 2;
  }
  // Account-owned tokens verify under the account; user tokens under /user. Try both, account first.
  let result: any = null;
  for (const path of [`/accounts/${encodeURIComponent(account)}/tokens/verify`, "/user/tokens/verify"]) {
    try {
      const response = await fetcher(`https://api.cloudflare.com/client/v4${path}`, { headers: { Authorization: `Bearer ${token}` } });
      const body: any = await response.json();
      if (response.ok && body?.success) { result = body.result; break; }
    } catch { /* try the next endpoint */ }
  }
  const verdict = judge(result);
  process.stdout.write(verdict.lines.join("\n") + "\n");
  return verdict.ok ? 0 : 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().then((code) => { process.exitCode = code; });
}
