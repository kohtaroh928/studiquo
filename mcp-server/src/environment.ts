// Tells staging's outgoing messages (Slack, push, e-mail, admin pages) apart
// from production's. The only input is the ENVIRONMENT_LABEL variable
// (wrangler.jsonc `vars`): set to "staging" on the staging Worker, unset on
// production, where nothing is marked. It is never a secret and never carries
// anything about a person, so it is safe to put in front of any text.
import type { Env } from "./env.ts";

/** "STAGING" for a staging deployment, null for production (or an unusable value). */
export function environmentTag(env: Pick<Env, "ENVIRONMENT_LABEL">): string | null {
  const label = (env.ENVIRONMENT_LABEL ?? "").trim().toUpperCase();
  // A short plain word only: the value ends up in Slack markup, HTML and e-mail subjects.
  if (!/^[A-Z0-9_-]{1,16}$/.test(label)) return null;
  return label === "PRODUCTION" || label === "PROD" ? null : label;
}

/** `text` with "[STAGING] " in front on a non-production deployment; unchanged on production. */
export function tagged(env: Pick<Env, "ENVIRONMENT_LABEL">, text: string): string {
  const tag = environmentTag(env);
  return tag ? `[${tag}] ${text}` : text;
}

/**
 * An admin page with "[STAGING]" in its title and a banner above its heading,
 * so a staging dashboard is never mistaken for production's. Production's
 * page is returned untouched.
 */
export function markAdminPage(env: Pick<Env, "ENVIRONMENT_LABEL">, html: string): string {
  const tag = environmentTag(env);
  if (!tag) return html;
  const banner = `<div style="background:#b45309;color:#fff;padding:.4rem .8rem;border-radius:6px;font-weight:600;margin:0 0 1rem">${tag}環境(本番ではありません)</div>`;
  return html.replace("<title>", `<title>[${tag}] `).replace("<h1", `${banner}\n<h1`);
}
