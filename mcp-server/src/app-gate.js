// Two switches the operator can flip without shipping an app update.
//
//   MAINTENANCE_MODE="true"  every app, MCP and OAuth route answers 503 with a
//                            Retry-After, so a faulty release or an incident can
//                            be held off while it is dealt with. The health
//                            check, the association file, the legal and invite
//                            pages, the public announcements and the admin
//                            pages stay up.
//   MIN_APP_BUILD="<n>"      app requests from a build older than <n> answer 426
//                            "update required". The build number comes from the
//                            User-Agent iOS gives every request ("studiquo/<build>
//                            CFNetwork/…"), so it works for builds that predate
//                            this check. A request that does not look like the app
//                            (another client, a browser) is never turned away.
//
// Both are unset by default, which turns them off.
import { json } from "./http.js";

function isGuardedRoute(pathname) {
  if (pathname === "/mcp" || pathname.startsWith("/oauth/")) return true;
  if (!pathname.startsWith("/api/")) return false;
  return !pathname.startsWith("/api/admin/") && pathname !== "/api/announcements";
}

export function appGateRejection(request, env, url) {
  if (!isGuardedRoute(url.pathname)) return null;
  if (env.MAINTENANCE_MODE === "true") {
    const response = json({ error: "ただいまメンテナンス中です。しばらくしてからもう一度お試しください。", code: "maintenance" }, 503);
    response.headers.set("retry-after", "300");
    return response;
  }
  const minimum = Number(env.MIN_APP_BUILD);
  if (Number.isFinite(minimum) && minimum > 0 && url.pathname.startsWith("/api/")) {
    const build = /^studiquo\/(\d+)(?:\s|$)/.exec(request.headers.get("user-agent") ?? "");
    if (build && Number(build[1]) < minimum) {
      return json({ error: "アプリを最新版に更新してください。", code: "app_update_required" }, 426);
    }
  }
  return null;
}
