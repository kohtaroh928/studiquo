// Transport hardening for every response the Worker gives:
//
//  - Strict-Transport-Security: a browser (or any client that honours it) that has
//    seen this host over https keeps using https for a year. No includeSubDomains
//    and no preload: this host is one of several under the domain.
//  - Plain http: Cloudflare's "Always Use HTTPS" turns http away at the edge, but it
//    is a dashboard setting and was found off. If an http request reaches the Worker
//    anyway, it is answered before anything is read: a GET is sent to https, anything
//    else is refused. (The request's headers, a bearer token among them, already
//    crossed the network in clear; the client should switch to https and treat the
//    token as seen.) Local development over http://localhost is left alone.
import { json } from "./http.ts";

export const HSTS_VALUE = "max-age=31536000";

function isLocalHost(hostname) {
  return hostname === "localhost" || hostname === "127.0.0.1" || hostname === "[::1]" || hostname.endsWith(".localhost");
}

/** A response for a request that came over plain http, or null for https and local development. */
export function plainHttpResponse(request, url) {
  if (url.protocol !== "http:" || isLocalHost(url.hostname)) return null;
  if (request.method === "GET" || request.method === "HEAD") {
    const secure = new URL(url);
    secure.protocol = "https:";
    return new Response(null, { status: 308, headers: { location: secure.toString(), "cache-control": "no-store", "strict-transport-security": HSTS_VALUE } });
  }
  return json({ error: "HTTPS is required.", code: "https_required" }, 403);
}

/** `response` with Strict-Transport-Security, unless it already has it or cannot take it. */
export function withTransportHeaders(response) {
  // A WebSocket handshake carries its socket on the response; rebuilding it would drop it.
  if (response.status === 101 || response.webSocket) return response;
  if (response.headers.has("strict-transport-security")) return response;
  try {
    response.headers.set("strict-transport-security", HSTS_VALUE);
    return response;
  } catch {
    // Headers of a response that came from fetch() are immutable: copy it.
    const copy = new Response(response.body, response);
    copy.headers.set("strict-transport-security", HSTS_VALUE);
    return copy;
  }
}
