import { bearerToken, sha256Hex } from "./auth.js";
import { json, readJSONLimited, readTextLimited } from "./http.js";
import { checkRateLimit, clientKey } from "./rate-limit.js";

const AUTH_TTL = 600;
const CODE_TTL = 300;
const ACCESS_TTL = 3600;
const REFRESH_TTL = 90 * 24 * 3600;
const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

function randomToken(bytes = 32) {
  const data = crypto.getRandomValues(new Uint8Array(bytes));
  return Array.from(data, value => value.toString(16).padStart(2, "0")).join("");
}

function pairingCode() {
  const data = crypto.getRandomValues(new Uint8Array(12));
  return Array.from(data, value => ALPHABET[value % ALPHABET.length]).join("");
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

async function issueTokens(env, sub, clientId, scope) {
  const accessToken = `mcp_${randomToken()}`;
  const accessHash = await sha256Hex(accessToken);
  await env.STUDIQUO_DATA.put(`mcp:access:${accessHash}`, JSON.stringify({ sub, clientId, scope }), { expirationTtl: ACCESS_TTL });
  const result = { access_token: accessToken, token_type: "Bearer", expires_in: ACCESS_TTL, scope };
  const refreshToken = `mcp_refresh_${randomToken()}`;
  await env.STUDIQUO_DATA.put(`mcp:refresh:${await sha256Hex(refreshToken)}`, JSON.stringify({ sub, clientId, scope }), { expirationTtl: REFRESH_TTL });
  result.refresh_token = refreshToken;
  return result;
}

export async function externalSession(env, request) {
  const token = bearerToken(request);
  if (!token?.startsWith("mcp_")) return null;
  const session = await env.STUDIQUO_DATA.get(`mcp:access:${await sha256Hex(token)}`, "json");
  if (!session?.sub || !session?.clientId) return null;
  if (!(await env.STUDIQUO_DATA.get(await grantKey(session.sub, session.clientId)))) return null;
  return session;
}

export async function pairingInfo(env, code) {
  if (!/^[A-Z2-9]{12}$/.test(code)) return null;
  const id = await env.STUDIQUO_DATA.get(`mcp:pair:${code}`);
  if (!id) return null;
  const pending = await env.STUDIQUO_DATA.get(`mcp:auth:${id}`, "json");
  return pending?.status === "pending" ? { clientName: pending.clientName, scope: pending.scope, code } : null;
}

export async function approvePairing(env, code, sub) {
  const info = await pairingInfo(env, code);
  if (!info) return false;
  const id = await env.STUDIQUO_DATA.get(`mcp:pair:${code}`);
  const pending = await env.STUDIQUO_DATA.get(`mcp:auth:${id}`, "json");
  if (!pending || pending.status !== "pending") return false;
  const authorizationCode = `mcp_code_${randomToken()}`;
  await env.STUDIQUO_DATA.put(`mcp:code:${await sha256Hex(authorizationCode)}`, JSON.stringify({
    sub, clientId: pending.clientId, redirectUri: pending.redirectUri,
    codeChallenge: pending.codeChallenge, scope: pending.scope,
  }), { expirationTtl: CODE_TTL });
  await env.STUDIQUO_DATA.put(await grantKey(sub, pending.clientId), JSON.stringify({
    clientName: pending.clientName, createdAt: Date.now(),
  }));
  await env.STUDIQUO_DATA.put(`mcp:auth:${id}`, JSON.stringify({ ...pending, status: "approved", authorizationCode }), { expirationTtl: CODE_TTL });
  await env.STUDIQUO_DATA.delete(`mcp:pair:${code}`);
  return true;
}

export async function listConnections(env, sub) {
  const prefix = `mcp:grant:${await sha256Hex(sub)}:`;
  const result = await env.STUDIQUO_DATA.list({ prefix });
  return Promise.all(result.keys.map(async key => ({
    id: key.name.slice(prefix.length),
    ...(await env.STUDIQUO_DATA.get(key.name, "json")),
  })));
}

export async function revokeConnection(env, sub, id) {
  if (!/^[a-f0-9]{64}$/.test(id)) return false;
  await env.STUDIQUO_DATA.delete(`mcp:grant:${await sha256Hex(sub)}:${id}`);
  return true;
}

export async function handleMCPOAuth(url, request, env) {
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
    await env.STUDIQUO_DATA.put(`mcp:client:${clientId}`, JSON.stringify({ clientName, redirectUris: uris }));
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
    const code = pairingCode();
    await env.STUDIQUO_DATA.put(`mcp:auth:${id}`, JSON.stringify({
      status: "pending", clientId, clientName: client.clientName, redirectUri,
      codeChallenge, scope, state: url.searchParams.get("state") ?? "",
    }), { expirationTtl: AUTH_TTL });
    await env.STUDIQUO_DATA.put(`mcp:pair:${code}`, id, { expirationTtl: AUTH_TTL });
    const page = `<!doctype html><html lang="ja"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>studiquoに接続</title><style>body{font:18px system-ui;max-width:32rem;margin:3rem auto;padding:1rem;line-height:1.6}code{font-size:2rem;letter-spacing:.2em}small{color:#555}</style><h1>studiquoに接続</h1><p>${htmlEscape(client.clientName)}が資料の参照と作成を求めています。</p><p>studiquoアプリの「MCPクラウド連携」で次のコードを入力し、接続を許可してください。</p><p><code>${code}</code></p><small>この画面を開いたままにしてください。コードは10分で期限切れになります。</small><p id="status"></p><script>setInterval(async()=>{try{let r=await fetch('/oauth/status?id=${id}',{cache:'no-store'});let x=await r.json();if(x.redirect){location.assign(x.redirect)}else if(x.status==='expired'){document.getElementById('status').textContent='期限が切れました。接続をやり直してください。'}}catch{}},2000)</script></html>`;
    return new Response(page, { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "content-security-policy": "default-src 'none'; script-src 'unsafe-inline'; connect-src 'self'; style-src 'unsafe-inline'" } });
  }
  if (url.pathname === "/oauth/status" && request.method === "GET") {
    const id = url.searchParams.get("id") ?? "";
    if (!/^[a-f0-9]{64}$/.test(id)) return json({ status: "expired" });
    const pending = await env.STUDIQUO_DATA.get(`mcp:auth:${id}`, "json");
    if (!pending) return json({ status: "expired" });
    if (pending.status !== "approved") return json({ status: "pending" });
    const redirect = new URL(pending.redirectUri);
    redirect.searchParams.set("code", pending.authorizationCode);
    if (pending.state) redirect.searchParams.set("state", pending.state);
    return json({ status: "approved", redirect: redirect.toString() });
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
      if (challenge !== code.codeChallenge) return json({ error: "invalid_grant" }, 400);
      const accountHash = await sha256Hex(`mcp-account:${code.sub}`);
      if (!(await env.MCP_INBOX.getByName(accountHash).consumeOnce(await sha256Hex(rawCode)))) {
        return json({ error: "invalid_grant" }, 400);
      }
      await env.STUDIQUO_DATA.delete(storedKey);
      return json(await issueTokens(env, code.sub, clientId, code.scope));
    }
    if (grantType === "refresh_token") {
      const raw = String(form.get("refresh_token") ?? "");
      const key = `mcp:refresh:${await sha256Hex(raw)}`;
      const refresh = await env.STUDIQUO_DATA.get(key, "json");
      if (!refresh || refresh.clientId !== clientId || !(await env.STUDIQUO_DATA.get(await grantKey(refresh.sub, clientId)))) {
        return json({ error: "invalid_grant" }, 400);
      }
      const accountHash = await sha256Hex(`mcp-account:${refresh.sub}`);
      if (!(await env.MCP_INBOX.getByName(accountHash).consumeOnce(await sha256Hex(raw)))) {
        return json({ error: "invalid_grant" }, 400);
      }
      await env.STUDIQUO_DATA.delete(key);
      return json(await issueTokens(env, refresh.sub, clientId, refresh.scope));
    }
    return json({ error: "unsupported_grant_type" }, 400);
  }
  return null;
}
