// Shared HTTP plumbing for the Worker's fetch handlers: the security headers
// every JSON response should carry, and a single byte-limited body reader so
// each route file doesn't reimplement the same streaming-read loop.

export function securityHeaders(extra = {}) {
  return {
    "cache-control": "no-store",
    "content-security-policy": "default-src 'none'; frame-ancestors 'none'",
    "referrer-policy": "no-referrer",
    "x-content-type-options": "nosniff",
    ...extra,
  };
}

/**
 * Headers for a response that is just stored bytes (a profile photo, a chat
 * attachment, a report screenshot). The content type was chosen by whoever
 * uploaded it, so the browser is told not to guess a different one and the
 * body is sandboxed: even if it is really HTML, it cannot run script.
 * `download` also marks it as a file to save rather than a page to show.
 */
export function binaryHeaders(contentType, cacheControl, { download = false } = {}) {
  return {
    "content-type": contentType,
    "cache-control": cacheControl,
    "content-security-policy": "default-src 'none'; sandbox",
    "referrer-policy": "no-referrer",
    "x-content-type-options": "nosniff",
    ...(download ? { "content-disposition": "attachment" } : {}),
  };
}

export function json(value, status = 200) {
  return Response.json(value, { status, headers: securityHeaders() });
}

/**
 * Reads `request`'s body as text, capping it at `maximumBytes` of actual
 * streamed bytes (not just the declared Content-Length, which a caller can
 * misreport). Returns `null` if the body exceeds the limit, or `""` if there
 * is no body at all.
 */
export async function readTextLimited(request, maximumBytes) {
  if (!request.body) return "";
  const reader = request.body.getReader();
  const decoder = new TextDecoder();
  let received = 0;
  let result = "";
  while (true) {
    const { done, value } = await reader.read();
    if (done) return result + decoder.decode();
    received += value.byteLength;
    if (received > maximumBytes) {
      await reader.cancel();
      return null;
    }
    result += decoder.decode(value, { stream: true });
  }
}

/**
 * Like `readTextLimited`, but also parses the result as JSON. Returns `null`
 * for a missing body, an oversized body (checked against both the declared
 * Content-Length and the actual bytes read), or invalid JSON — callers that
 * need to distinguish those cases (e.g. to return a specific error message)
 * should use `readTextLimited` and `JSON.parse` directly instead.
 */
export async function readJSONLimited(request, maximumBytes) {
  const declaredSize = Number(request.headers.get("content-length") ?? 0);
  if (!request.body || declaredSize > maximumBytes) return null;
  const text = await readTextLimited(request, maximumBytes);
  if (text == null) return null;
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}
