// Append-only record of what the operator did through /api/admin/* (see
// migrations/0007_moderation.sql). Written BEFORE the action, and a failed
// write refuses the action: reading a person's report or pushing to every
// device is not something that should be possible unrecorded.
import { accessActor } from "./access.ts";

const MAX_FIELD = 200;

export async function auditAdmin(env, request, action, target = "", detail = "") {
  if (!env.ADMIN_DB) throw new Error("Audit log unavailable");
  const actor = (await accessActor(request, env)) ?? "unknown";
  await env.ADMIN_DB.prepare(
    "INSERT INTO admin_audit_log (at, actor, action, target, detail) VALUES (?, ?, ?, ?, ?)"
  ).bind(Date.now(), actor.slice(0, MAX_FIELD), action, String(target).slice(0, MAX_FIELD), String(detail).slice(0, MAX_FIELD)).run();
}
