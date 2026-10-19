import { bearerToken, secretsEqual, sha256Hex } from "./auth.js";
import { json, readJSONLimited, readTextLimited } from "./http.js";
import { checkRateLimit, clientKey } from "./rate-limit.js";
import { accountIsUnavailable } from "./session.js";
import { resolveChatUserKey } from "./chat-identity.js";
import { sendPush } from "./push.js";
import { accessTokenAcceptable, signAccessToken } from "./token-signature.js";

const AUTH_TTL = 600;
const CODE_TTL = 300;
const ACCESS_TTL = 3600;
const REFRESH_TTL = 90 * 24 * 3600;
// A registration nobody uses again goes away; one in use is needed again only
// when the app is connected anew.
const CLIENT_TTL = 365 * 24 * 3600;
const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

function randomToken(bytes = 32) {
  const data = crypto.getRandomValues(new Uint8Array(bytes));
  return Array.from(data, value => value.toString(16).padStart(2, "0")).join("");
}

function pairingCode() {
  const data = crypto.getRandomValues(new Uint8Array(12));
  return Array.from(data, value => ALPHABET[value % ALPHABET.length]).join("");
}

export const CONNECTION_KINDS = ["claude", "chatgpt", "codex", "other"];
// A code the owner makes in the app lives this long and works once.
const OWNER_CODE_TTL = 300;
// Wrong codes tried on one authorize page, and from one address.
const FLOW_ATTEMPTS = 5;
const IP_ATTEMPTS = 20;
const IP_ATTEMPT_WINDOW = 600;

// What kind of AI app a registered client is, judged from where it sends the
// owner back to. Anyone can register a client under any name, but not under
// someone else's address, so the address is what the kind rests on. A code made
// for "claude" therefore cannot be spent on a client that is not at claude.ai.
export function classifyClient(client) {
  const hosts = [];
  for (const value of client?.redirectUris ?? []) {
    try { hosts.push(new URL(value).hostname); } catch { /* ignored */ }
  }
  if (hosts.length === 0) return "other";
  const under = (host, domain) => host === domain || host.endsWith(`.${domain}`);
  if (hosts.every(host => under(host, "claude.ai") || under(host, "claude.com"))) return "claude";
  if (hosts.every(host => under(host, "chatgpt.com") || under(host, "chat.openai.com") || under(host, "openai.com"))) return "chatgpt";
  const loopback = hosts.every(host => ["localhost", "127.0.0.1", "[::1]"].includes(host));
  if (loopback && /codex/i.test(client?.clientName ?? "")) return "codex";
  return "other";
}

export function normalizeCode(value) {
  return String(value ?? "").toUpperCase().replace(/[\s-]/g, "");
}

async function ownerCodeKey(code) {
  return `mcp:owner-code:${await sha256Hex(code)}`;
}

/**
 * The owner asks for a code in the app and types it into the AI app's own
 * page. Only the owner's signed-in session can make one, it is for one kind of
 * app, lasts five minutes and works once. A new code replaces the last one.
 */
export async function issueOwnerCode(env, sub, kind) {
  if (!CONNECTION_KINDS.includes(kind)) return null;
  const activeKey = `mcp:owner-code-active:${await sha256Hex(sub)}`;
  const previous = await env.STUDIQUO_DATA.get(activeKey);
  if (previous) await env.STUDIQUO_DATA.delete(previous);
  const code = pairingCode();
  const key = await ownerCodeKey(code);
  await env.STUDIQUO_DATA.put(key, JSON.stringify({ sub, kind }), { expirationTtl: OWNER_CODE_TTL });
  await env.STUDIQUO_DATA.put(activeKey, key, { expirationTtl: OWNER_CODE_TTL });
  return { code, kind, expiresInSeconds: OWNER_CODE_TTL };
}

function htmlEscape(value) {
  return String(value).replace(/[&<>"']/g, character => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  })[character]);
}

function validRedirect(value) {
  try {
    const url = new URL(value);
    return !url.username && !url.password && !url.hash &&
      (url.protocol === "https:" || (url.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)));
  } catch { return false; }
}

async function grantKey(sub, clientId) {
  return `mcp:grant:${await sha256Hex(sub)}:${await sha256Hex(clientId)}`;
}

// A grant carries a `nonce` made when the owner approves the app, and every
// token issued under it carries that value as `grantId`. Revoking deletes the
// grant; approving the same app again makes a new one with a new nonce, so
// tokens from before the revocation do not come back to life with it. A grant
// from before nonces existed has none, and neither do its tokens: those match.
function sameGeneration(grant, token) {
  return (grant?.nonce ?? null) === (token?.grantId ?? null);
}

// Tokens are listed per account (mcp:token-index:<account>:...) so deleting an
// account does not have to read every token there is. Tokens issued before
// this list existed are in no list; they all expire within REFRESH_TTL, so the
// first time one was issued under the list is remembered, and only once that
// is longer ago than REFRESH_TTL do account deletions stop scanning for them.
export const TOKEN_INDEX_STARTED_KEY = "mcp:token-index-since";
export const TOKEN_INDEX_COVERS_AFTER_MS = (REFRESH_TTL + 24 * 3600) * 1000;

async function markTokenIndexStarted(env) {
  if (!(await env.STUDIQUO_DATA.get(TOKEN_INDEX_STARTED_KEY))) {
    await env.STUDIQUO_DATA.put(TOKEN_INDEX_STARTED_KEY, String(Date.now()));
  }
}

export async function tokenIndexCoversEverything(env, now = Date.now()) {
  const since = Number(await env.STUDIQUO_DATA.get(TOKEN_INDEX_STARTED_KEY));
  return Number.isFinite(since) && since > 0 && now > since + TOKEN_INDEX_COVERS_AFTER_MS;
}

async function issueTokens(env, sub, clientId, scope, grantId) {
  const generation = grantId ? { grantId } : {};
  // Signed when a key is configured, so a made-up access token is refused before
  // KV is read (token-signature.js).
  const accessToken = await signAccessToken(env, `mcp_${randomToken()}`);
  const accessHash = await sha256Hex(accessToken);
  await env.STUDIQUO_DATA.put(`mcp:access:${accessHash}`, JSON.stringify({ sub, clientId, scope, ...generation }), { expirationTtl: ACCESS_TTL });
  const subHash = await sha256Hex(sub);
  await env.STUDIQUO_DATA.put(`mcp:token-index:${subHash}:access:${accessHash}`, "1", { expirationTtl: ACCESS_TTL });
  const result = { access_token: accessToken, token_type: "Bearer", expires_in: ACCESS_TTL, scope };
  const refreshToken = `mcp_refresh_${randomToken()}`;
  const refreshHash = await sha256Hex(refreshToken);
  await env.STUDIQUO_DATA.put(`mcp:refresh:${refreshHash}`, JSON.stringify({ sub, clientId, scope, ...generation }), { expirationTtl: REFRESH_TTL });
  await env.STUDIQUO_DATA.put(`mcp:token-index:${subHash}:refresh:${refreshHash}`, "1", { expirationTtl: REFRESH_TTL });
  await markTokenIndexStarted(env);
  result.refresh_token = refreshToken;
  return result;
}

export async function externalSession(env, request) {
  const token = bearerToken(request);
  if (!token?.startsWith("mcp_")) return null;
  if (!(await accessTokenAcceptable(env, token))) return null;
  const session = await env.STUDIQUO_DATA.get(`mcp:access:${await sha256Hex(token)}`, "json");
  if (!session?.sub || !session?.clientId) return null;
  const grant = await env.STUDIQUO_DATA.get(await grantKey(session.sub, session.clientId), "json");
  if (!grant || !sameGeneration(grant, session)) return null;
  // A token issued before the account was deleted must stop working at once,
  // not only when its own expiry comes.
  if (await accountIsUnavailable(env, session.sub)) return null;
  return session;
}

// The authorize page's owner typed a right code: grant the app and hand back
// where to send them, authorization code attached.
async function approveFlow(env, flowId, pending, sub) {
  const authorizationCode = `mcp_code_${randomToken()}`;
  await env.STUDIQUO_DATA.put(`mcp:code:${await sha256Hex(authorizationCode)}`, JSON.stringify({
    sub, clientId: pending.clientId, redirectUri: pending.redirectUri,
    codeChallenge: pending.codeChallenge, scope: pending.scope,
  }), { expirationTtl: CODE_TTL });
  await env.STUDIQUO_DATA.put(await grantKey(sub, pending.clientId), JSON.stringify({
    clientName: pending.clientName, kind: pending.kind, createdAt: Date.now(), nonce: randomToken(),
  }));
  await env.STUDIQUO_DATA.delete(`mcp:auth:${flowId}`);
  const redirect = new URL(pending.redirectUri);
  redirect.searchParams.set("code", authorizationCode);
  if (pending.state) redirect.searchParams.set("state", pending.state);
  return redirect.toString();
}

// Tells the owner's devices that an app was just connected, so a connection
// they did not make is noticed. Best effort: the connection stands either way.
async function notifyConnected(env, sub, pending) {
  try {
    const userKey = await resolveChatUserKey(env, sub, null);
    if (!userKey) return;
    await sendPush(env, userKey, {
      title: "AIアプリが接続されました",
      body: `${pending.clientName}がstudiquoに接続されました。心当たりがなければ、設定から接続を解除してください。`,
      data: { route: "mcpConnections" },
    });
  } catch (error) {
    console.error(JSON.stringify({ event: "mcp_connect_push_failed", error: error instanceof Error ? error.message : String(error) }));
  }
}

export async function listConnections(env, sub) {
  const prefix = `mcp:grant:${await sha256Hex(sub)}:`;
  const names = [];
  let cursor;
  do {
    const page = await env.STUDIQUO_DATA.list({ prefix, ...(cursor ? { cursor } : {}) });
    names.push(...page.keys.map(key => key.name));
    cursor = page.list_complete === false ? page.cursor : undefined;
  } while (cursor);
  // Only what the app lists: the grant's `nonce` is what ties issued tokens to
  // it, so it stays server-side.
  return Promise.all(names.map(async name => {
    const grant = await env.STUDIQUO_DATA.get(name, "json");
    return { id: name.slice(prefix.length), clientName: grant?.clientName ?? null, kind: grant?.kind ?? null, createdAt: grant?.createdAt ?? null };
  }));
}

/**
 * Disconnects every connected app (grant) of the account, e.g. when its
 * password is reset. A grant is keyed by the identity that approved it, so an
 * app approved before two sign-in methods were linked sits under the other
 * identity: pass the account's own key together with every linked identity.
 */
export async function revokeAllConnections(env, subs) {
  for (const sub of new Set(Array.isArray(subs) ? subs : [subs])) {
    for (const connection of await listConnections(env, sub)) await revokeConnection(env, sub, connection.id);
  }
}

export async function revokeConnection(env, sub, id) {
  if (!/^[a-f0-9]{64}$/.test(id)) return false;
  await env.STUDIQUO_DATA.delete(`mcp:grant:${await sha256Hex(sub)}:${id}`);
  return true;
}

export async function handleMCPOAuth(url, request, env, ctx) {
  const origin = url.origin;
  if (url.pathname === "/.well-known/oauth-protected-resource" || url.pathname === "/.well-known/oauth-protected-resource/mcp") {
    return json({ resource: `${origin}/mcp`, authorization_servers: [origin], scopes_supported: ["studiquo.read", "studiquo.write"] });
  }
  if (url.pathname === "/.well-known/oauth-authorization-server") {
    return json({
      issuer: origin,
      authorization_endpoint: `${origin}/oauth/authorize`,
      token_endpoint: `${origin}/oauth/token`,
      registration_endpoint: `${origin}/oauth/register`,
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      code_challenge_methods_supported: ["S256"],
      token_endpoint_auth_methods_supported: ["none"],
      scopes_supported: ["studiquo.read", "studiquo.write"],
    });
  }
  if (url.pathname === "/oauth/register" && request.method === "POST") {
    if (!(await checkRateLimit(env.RATE_LIMIT_MCP_REGISTER, clientKey(request)))) return json({ error: "rate_limited" }, 429);
    const body = await readJSONLimited(request, 20_000);
    const uris = body?.redirect_uris;
    if (!Array.isArray(uris) || uris.length < 1 || uris.length > 10 || !uris.every(uri => typeof uri === "string" && validRedirect(uri))) {
      return json({ error: "invalid_client_metadata" }, 400);
    }
    const clientId = `studiquo_${randomToken(16)}`;
    const clientName = String(body.client_name ?? "MCP client").slice(0, 100);
    await env.STUDIQUO_DATA.put(`mcp:client:${clientId}`, JSON.stringify({ clientName, redirectUris: uris }), { expirationTtl: CLIENT_TTL });
    return json({ client_id: clientId, client_name: clientName, redirect_uris: uris,
      token_endpoint_auth_method: "none", grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"] }, 201);
  }
  if (url.pathname === "/oauth/authorize" && request.method === "GET") {
    if (!(await checkRateLimit(env.RATE_LIMIT_MCP_AUTHORIZE, clientKey(request)))) return json({ error: "rate_limited" }, 429);
    const clientId = url.searchParams.get("client_id") ?? "";
    if (!/^studiquo_[a-f0-9]{32}$/.test(clientId)) return json({ error: "invalid_client" }, 400);
    const client = await env.STUDIQUO_DATA.get(`mcp:client:${clientId}`, "json");
    const redirectUri = url.searchParams.get("redirect_uri") ?? "";
    const codeChallenge = url.searchParams.get("code_challenge") ?? "";
    const scope = url.searchParams.get("scope") || "studiquo.read studiquo.write";
    if ((url.searchParams.get("state") ?? "").length > 500) return json({ error: "invalid_request" }, 400);
    if (!scope.split(/\s+/).every(value => ["studiquo.read", "studiquo.write"].includes(value))) {
      return json({ error: "invalid_scope" }, 400);
    }
    if (!client || !client.redirectUris.includes(redirectUri) || url.searchParams.get("response_type") !== "code" ||
        url.searchParams.get("code_challenge_method") !== "S256" || !/^[A-Za-z0-9_-]{43,128}$/.test(codeChallenge)) {
      return json({ error: "invalid_request" }, 400);
    }
    const id = randomToken();
    const kind = classifyClient(client);
    await env.STUDIQUO_DATA.put(`mcp:auth:${id}`, JSON.stringify({
      clientId, clientName: client.clientName, redirectUri, kind,
      codeChallenge, scope, state: url.searchParams.get("state") ?? "",
    }), { expirationTtl: AUTH_TTL });
    const kindName = ({ claude: "Claude", chatgpt: "ChatGPT", codex: "Codex", other: "このAIアプリ" })[kind];
    const page = `<!doctype html><html lang="ja"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>studiquoに接続</title><style>body{font:18px system-ui;max-width:32rem;margin:3rem auto;padding:1rem;line-height:1.6}input{font:1.6rem monospace;letter-spacing:.15em;width:100%;box-sizing:border-box;padding:.4rem;text-transform:uppercase}button{font-size:1.1rem;padding:.6rem 1.2rem;margin-top:.8rem}small{color:#555}#msg{color:#b00020}</style><h1>studiquoに接続</h1><p>${htmlEscape(client.clientName)}(${kindName}として登録)が資料の参照と作成を求めています。</p><p>studiquoアプリの「AIアプリを接続する」で「${kindName}」を選んでコードを発行し、ここに入力してください。</p><form id="f"><input id="code" autocomplete="off" autocapitalize="characters" spellcheck="false" maxlength="20" placeholder="XXXX-XXXX-XXXX" aria-label="接続コード"><button type="submit">接続する</button></form><p id="msg" role="alert"></p><small>コードはあなたがstudiquoアプリで発行したものだけを入力してください。他の人から送られたコードは入力しないでください。</small><script>document.getElementById('f').addEventListener('submit',async e=>{e.preventDefault();let m=document.getElementById('msg');m.textContent='';try{let r=await fetch('/oauth/pair',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({id:'${id}',code:document.getElementById('code').value})});let x=await r.json();if(x.redirect){location.assign(x.redirect)}else{m.textContent=x.message||'接続できませんでした。'}}catch{m.textContent='通信に失敗しました。'}})</script></html>`;
    return new Response(page, { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "content-security-policy": "default-src 'none'; script-src 'unsafe-inline'; connect-src 'self'; style-src 'unsafe-inline'; frame-ancestors 'none'", "x-content-type-options": "nosniff", "referrer-policy": "no-referrer" } });
  }
  if (url.pathname === "/oauth/pair" && request.method === "POST") {
    const fail = (message, status = 400) => json({ error: "invalid_code", message }, status);
    if (!(await checkRateLimit(env.RATE_LIMIT_MCP_PAIR, clientKey(request)))) return fail("試行が多すぎます。しばらくしてからやり直してください。", 429);
    const body = await readJSONLimited(request, 1_000);
    const id = String(body?.id ?? "");
    const code = normalizeCode(body?.code);
    if (!/^[a-f0-9]{64}$/.test(id)) return fail("この画面は期限切れです。AIアプリから接続をやり直してください。");
    const pending = await env.STUDIQUO_DATA.get(`mcp:auth:${id}`, "json");
    if (!pending) return fail("この画面は期限切れです。AIアプリから接続をやり直してください。");
    // Guessing is capped per page and per address; a page that has used up its
    // tries is closed, so the owner starts again from the AI app.
    const ip = await sha256Hex(clientKey(request));
    const ipOk = await env.RATE_COUNTER.getByName(`mcp-pair-ip:${ip}`).bump(IP_ATTEMPTS, IP_ATTEMPT_WINDOW);
    const flowOk = await env.RATE_COUNTER.getByName(`mcp-pair-flow:${id}`).bump(FLOW_ATTEMPTS, AUTH_TTL);
    if (!flowOk) {
      await env.STUDIQUO_DATA.delete(`mcp:auth:${id}`);
      return fail("間違いが続いたため、この画面を閉じました。AIアプリから接続をやり直してください。", 429);
    }
    if (!ipOk) return fail("試行が多すぎます。しばらくしてからやり直してください。", 429);
    if (!/^[A-Z2-9]{12}$/.test(code)) return fail("コードが正しくないか、期限が切れています。");
    const key = await ownerCodeKey(code);
    const issued = await env.STUDIQUO_DATA.get(key, "json");
    if (!issued?.sub) return fail("コードが正しくないか、期限が切れています。");
    // A code made for one kind of app is not spent on another; it stays valid
    // for the app it was made for.
    if (issued.kind !== pending.kind) return fail("このコードは別の種類のAIアプリ用です。接続したいAIアプリに合わせてコードを発行してください。");
    // Works once, even if two pages submit it at the same moment.
    if (!(await env.RATE_COUNTER.getByName(`mcp-code-use:${key}`).bump(1, OWNER_CODE_TTL))) return fail("コードが正しくないか、期限が切れています。");
    await env.STUDIQUO_DATA.delete(key);
    await env.STUDIQUO_DATA.delete(`mcp:owner-code-active:${await sha256Hex(issued.sub)}`);
    const redirect = await approveFlow(env, id, pending, issued.sub);
    const notice = notifyConnected(env, issued.sub, pending);
    if (typeof ctx?.waitUntil === "function") ctx.waitUntil(notice); else await notice;
    return json({ redirect });
  }
  if (url.pathname === "/oauth/token" && request.method === "POST") {
    if (!(await checkRateLimit(env.RATE_LIMIT_MCP_TOKEN, clientKey(request)))) return json({ error: "rate_limited" }, 429);
    const raw = await readTextLimited(request, 8_000);
    if (raw == null) return json({ error: "invalid_request" }, 400);
    const form = new URLSearchParams(raw);
    const grantType = String(form.get("grant_type") ?? "");
    const clientId = String(form.get("client_id") ?? "");
    if (grantType === "authorization_code") {
      const rawCode = String(form.get("code") ?? "");
      const storedKey = `mcp:code:${await sha256Hex(rawCode)}`;
      const code = await env.STUDIQUO_DATA.get(storedKey, "json");
      const verifier = String(form.get("code_verifier") ?? "");
      if (!code || code.clientId !== clientId || code.redirectUri !== String(form.get("redirect_uri") ?? "") ||
          !/^[A-Za-z0-9._~-]{43,128}$/.test(verifier)) return json({ error: "invalid_grant" }, 400);
      const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
      const challenge = btoa(String.fromCharCode(...new Uint8Array(digest))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
      if (!(await secretsEqual(challenge, code.codeChallenge))) return json({ error: "invalid_grant" }, 400);
      if (await accountIsUnavailable(env, code.sub)) return json({ error: "invalid_grant" }, 400);
      const accountHash = await sha256Hex(`mcp-account:${code.sub}`);
      if (!(await env.MCP_INBOX.getByName(accountHash).consumeOnce(await sha256Hex(rawCode)))) {
        return json({ error: "invalid_grant" }, 400);
      }
      const grant = await env.STUDIQUO_DATA.get(await grantKey(code.sub, clientId), "json");
      if (!grant) return json({ error: "invalid_grant" }, 400);
      await env.STUDIQUO_DATA.delete(storedKey);
      return json(await issueTokens(env, code.sub, clientId, code.scope, grant.nonce));
    }
    if (grantType === "refresh_token") {
      const raw = String(form.get("refresh_token") ?? "");
      const key = `mcp:refresh:${await sha256Hex(raw)}`;
      const refresh = await env.STUDIQUO_DATA.get(key, "json");
      if (!refresh) {
        // A refresh token that was already exchanged is presented again: either a
        // client lost the reply and retried, or a copy of it was stolen. Both
        // holders cannot be told apart, so the connection is cut (the owner
        // approves the app again) and every token issued under it stops working.
        const spent = await env.STUDIQUO_DATA.get(`mcp:refresh-used:${await sha256Hex(raw)}`, "json");
        if (spent?.sub && spent.clientId === clientId) {
          await env.STUDIQUO_DATA.delete(await grantKey(spent.sub, clientId));
          console.warn(JSON.stringify({ message: "mcp refresh token reused; connection revoked" }));
        }
        return json({ error: "invalid_grant" }, 400);
      }
      const grant = refresh && refresh.clientId === clientId ? await env.STUDIQUO_DATA.get(await grantKey(refresh.sub, clientId), "json") : null;
      if (!grant || !sameGeneration(grant, refresh)) {
        return json({ error: "invalid_grant" }, 400);
      }
      if (await accountIsUnavailable(env, refresh.sub)) return json({ error: "invalid_grant" }, 400);
      const accountHash = await sha256Hex(`mcp-account:${refresh.sub}`);
      if (!(await env.MCP_INBOX.getByName(accountHash).consumeOnce(await sha256Hex(raw)))) {
        return json({ error: "invalid_grant" }, 400);
      }
      // Remembered (not just deleted) so that a second use can be recognised.
      await env.STUDIQUO_DATA.put(`mcp:refresh-used:${await sha256Hex(raw)}`, JSON.stringify({ sub: refresh.sub, clientId }), { expirationTtl: REFRESH_TTL });
      await env.STUDIQUO_DATA.delete(key);
      return json(await issueTokens(env, refresh.sub, clientId, refresh.scope, grant.nonce));
    }
    return json({ error: "unsupported_grant_type" }, 400);
  }
  return null;
}
