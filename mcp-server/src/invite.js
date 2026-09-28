// Serves the https:// landing page a friend-invite link points at (see
// FriendStore.invitationURL in the Swift app). On a device where Universal
// Links actually matched (see passkeys.js's associationFile), iOS opens
// Studiquo directly and this page is never shown at all. It only renders
// when that hand-off didn't happen — most commonly because the link was
// tapped inside another app's in-app browser (LINE, Snapchat, …), which
// generally won't route a studiquo:// custom-scheme link to iOS but will
// load a real https:// page like this one.
import { json } from "./http.js";

function htmlEscape(value) {
  return String(value).replace(/[&<>"']/g, character => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  })[character]);
}

export function handleInvitePage(url) {
  if (url.pathname !== "/invite") return null;

  const token = (url.searchParams.get("token") ?? "").trim();
  if (!/^[A-Za-z0-9]{6,32}$/.test(token)) {
    return json({ error: "Invalid invite link." }, 400);
  }

  const appLink = `studiquo://friend/add?token=${encodeURIComponent(token)}`;
  const page = `<!doctype html><html lang="ja"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Studiquoに接続</title><style>body{font:18px system-ui;max-width:28rem;margin:4rem auto;padding:1rem;line-height:1.6;text-align:center}a.button{display:inline-block;margin-top:1.5rem;padding:0.9rem 2rem;background:#0a7cff;color:#fff;text-decoration:none;border-radius:999px;font-weight:600}small{color:#777;display:block;margin-top:2rem}</style><h1>studiquo</h1><p>フレンド招待リンクです。「Studiquoで開く」をタップしてください。</p><a class="button" href="${htmlEscape(appLink)}">Studiquoで開く</a><small>アプリが自動で開かない場合は、上のボタンをもう一度タップしてください。studiquoアプリがインストールされている必要があります。</small><script>location.replace(${JSON.stringify(appLink)})</script></html>`;
  return new Response(page, {
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
  });
}
