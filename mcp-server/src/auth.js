// Shared by every module that authenticates a request with a Studiquo bearer
// token, so the extraction rule and the hashing algorithm used to derive a
// user's storage key can't drift between them. revocation.js and token.js
// both assume every caller hashes the same raw token the same way — a
// separately-maintained copy of either function here would risk silently
// breaking that assumption for just one endpoint.

export function bearerToken(request) {
  const match = /^Bearer\s+(.+)$/i.exec(request.headers.get("authorization") ?? "");
  const token = match?.[1]?.trim() ?? "";
  return token.length >= 32 && token.length <= 256 ? token : null;
}

export async function sha256Hex(value) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("");
}
