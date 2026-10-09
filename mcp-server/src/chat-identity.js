import { sha256Hex } from "./auth.js";

// A person's chat identity must not change when their session does: friend
// codes, chat rooms and document rooms are all recorded under it. The first
// time an account is seen, the registry keeps the key derived from that
// token (`tokenKey`) so that accounts created before this indirection existed
// keep working; from then on every session of the account resolves to it.
//
// Without a registry binding (a plain test environment) the session's own
// token hash is used, which is what these routes did before.
export async function resolveChatUserKey(env, sub, tokenKey) {
  if (!env.USER_REGISTRY || !sub) return tokenKey;
  const identityHash = await sha256Hex(`chat-account:${sub}`);
  return env.USER_REGISTRY.getByName(identityHash).resolveChatKey(identityHash, tokenKey);
}
