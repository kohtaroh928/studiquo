import { sha256Hex } from "./auth.js";

// A person's chat identity must not change when their session does: friend
// codes, chat rooms and document rooms are all recorded under it. The registry
// settles the key the first time the account is seen and returns it from then
// on: the key derived from `tokenKey` if a chat user already exists under it
// (accounts created before this indirection existed), otherwise one derived
// from the account itself.
//
// Without a registry binding (a plain test environment) the session's own
// token hash is used, which is what these routes did before.
export async function resolveChatUserKey(env, sub, tokenKey) {
  if (!env.USER_REGISTRY || !sub) return tokenKey;
  const identityHash = await sha256Hex(`chat-account:${sub}`);
  return env.USER_REGISTRY.getByName(identityHash).resolveChatKey(identityHash, tokenKey);
}
