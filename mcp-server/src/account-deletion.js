import { sha256Hex } from "./auth.js";

async function entries(env, prefix) {
  const result = [];
  let cursor;
  do {
    const page = await env.STUDIQUO_DATA.list({ prefix, cursor });
    for (const item of page.keys ?? []) result.push(item.name);
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
  return result;
}

async function deleteKeys(env, keys) {
  await Promise.all([...new Set(keys)].map(key => env.STUDIQUO_DATA.delete(key)));
}

function linkedIdentityKey(identity) {
  if (identity.provider === "google") return `google:${identity.sub}`;
  if (identity.provider === "email") return `email:${identity.sub}`;
  return identity.sub;
}

export async function deleteAccount(env, canonicalSub) {
  const deletionStateKey = `account-deletion:${await sha256Hex(canonicalSub)}`;
  const previousState = await env.STUDIQUO_DATA.get(deletionStateKey, "json");
  const checkpointKeys = new Set(previousState?.deletionKeys ?? []);
  await env.STUDIQUO_DATA.put(deletionStateKey, JSON.stringify({ status: "deleting", deletionKeys: [...checkpointKeys] }));

  const ownerKeys = await entries(env, "email-account-owner:");
  const emails = [];
  const identities = [];
  for (const ownerKey of ownerKeys) {
    if (await env.STUDIQUO_DATA.get(ownerKey) !== canonicalSub) continue;
    const email = ownerKey.slice("email-account-owner:".length);
    emails.push(email);
    const linked = await env.STUDIQUO_DATA.get(`email-accounts:${email}`, "json") ?? [];
    identities.push(...linked);
  }

  // Older deployments may have the email-accounts list without the newer
  // owner record. Discover those lists directly so account deletion also
  // migrates forward safely instead of leaving historical identities behind.
  for (const linkKey of await entries(env, "email-accounts:")) {
    const email = linkKey.slice("email-accounts:".length);
    if (emails.includes(email)) continue;
    const linked = await env.STUDIQUO_DATA.get(linkKey, "json") ?? [];
    let belongsToAccount = false;
    for (const identity of linked) {
      const key = linkedIdentityKey(identity);
      const mapped = await env.STUDIQUO_DATA.get(`identity-canonical:${key}`);
      if (key === canonicalSub || mapped === canonicalSub) belongsToAccount = true;
    }
    if (belongsToAccount) {
      emails.push(email);
      identities.push(...linked);
    }
  }

  const identityKeys = new Set([canonicalSub]);
  for (const identity of identities) identityKeys.add(linkedIdentityKey(identity));
  // Also cover partially-migrated environments where aliases exist but the
  // email link list is absent or incomplete.
  for (const aliasKey of await entries(env, "identity-canonical:")) {
    if (await env.STUDIQUO_DATA.get(aliasKey) === canonicalSub) {
      identityKeys.add(aliasKey.slice("identity-canonical:".length));
    }
  }

  const sessionKeys = await entries(env, "session:");
  const ownedSessionKeys = [];
  const ownedTokenHashes = [];
  for (const key of sessionKeys) {
    const session = await env.STUDIQUO_DATA.get(key, "json");
    if (!identityKeys.has(session?.sub)) continue;
    ownedSessionKeys.push(key);
    ownedTokenHashes.push(key.slice("session:".length));
  }
  for (const key of ownedSessionKeys) checkpointKeys.add(key);
  for (const tokenHash of ownedTokenHashes) {
    checkpointKeys.add(`snapshot:${tokenHash}`);
    checkpointKeys.add(`actions:${tokenHash}`);
  }
  // Persist the cleanup plan before revoking sessions. If a later binding
  // call times out, a retry still knows which token-derived data belonged to
  // this account even though those session rows are already gone.
  await env.STUDIQUO_DATA.put(deletionStateKey, JSON.stringify({ status: "deleting", deletionKeys: [...checkpointKeys] }));
  await deleteKeys(env, ownedSessionKeys);

  const accountKeys = [];
  for (const identity of identities) {
    if (identity.provider === "google") accountKeys.push(`account:google:${identity.sub}`);
    else if (identity.provider === "email") accountKeys.push(`account:local:${identity.sub}`);
    else accountKeys.push(`account:${identity.sub}`);
  }
  for (const key of identityKeys) {
    if (key.startsWith("google:")) accountKeys.push(`account:google:${key.slice(7)}`);
    else if (key.startsWith("email:")) accountKeys.push(`account:local:${key.slice(6)}`);
    else accountKeys.push(`account:${key}`);
  }
  if (canonicalSub.startsWith("google:")) accountKeys.push(`account:google:${canonicalSub.slice(7)}`);
  else if (canonicalSub.startsWith("email:")) accountKeys.push(`account:local:${canonicalSub.slice(6)}`);
  else accountKeys.push(`account:${canonicalSub}`);

  const passkeyCredentialKeys = await entries(env, "passkeys:credential:");
  const ownedCredentialKeys = [];
  for (const key of passkeyCredentialKeys) {
    const credential = await env.STUDIQUO_DATA.get(key, "json");
    if (emails.includes(String(credential?.email ?? "").toLowerCase())) ownedCredentialKeys.push(key);
  }
  const passkeyUserKeys = await entries(env, "passkeys:user:");
  const ownedPasskeyUserKeys = [];
  for (const key of passkeyUserKeys) {
    const credentials = await env.STUDIQUO_DATA.get(key, "json") ?? [];
    if (credentials.some(item => emails.includes(String(item.email ?? "").toLowerCase()))) ownedPasskeyUserKeys.push(key);
  }

  const chatIdentityHash = await sha256Hex(`chat-account:${canonicalSub}`);
  const chatKey = env.USER_REGISTRY
    ? await env.USER_REGISTRY.getByName(chatIdentityHash).resolveChatKey(chatIdentityHash, "")
    : chatIdentityHash;
  const chatUser = await env.STUDIQUO_DATA.get(`chat:user:${chatKey}`, "json");
  if (chatUser && env.USER_REGISTRY && env.CHAT_ROOM) {
    const relatedCodes = new Set([
      ...(chatUser.friends ?? []).map(item => item.code),
      ...(chatUser.incomingRequests ?? []).map(item => item.code),
      ...(chatUser.outgoingRequests ?? []).map(item => item.code),
    ]);
    for (const code of relatedCodes) {
      const friendKey = await env.STUDIQUO_DATA.get(`chat:code:${code}`);
      if (friendKey) await env.USER_REGISTRY.getByName(friendKey).removeAccountReferences(friendKey, chatUser.code);
    }
    for (const friend of chatUser.friends ?? []) {
      if (friend.roomID) await env.CHAT_ROOM.getByName(friend.roomID).removeDeletedAccount(chatKey);
    }
    for (const group of chatUser.groups ?? []) {
      await env.CHAT_ROOM.getByName(group.roomID).removeDeletedAccount(chatKey);
    }
  }

  const mcpHash = await sha256Hex(`mcp-account:${canonicalSub}`);
  const usageHash = await sha256Hex(`usage-account:${canonicalSub}`);
  const mcpKeys = [];
  for (const prefix of ["mcp:grant:", "mcp:access:", "mcp:refresh:"]) {
    for (const key of await entries(env, prefix)) {
      if (key.startsWith(`mcp:grant:${await sha256Hex(canonicalSub)}:`)) mcpKeys.push(key);
      else {
        const value = await env.STUDIQUO_DATA.get(key, "json");
        if (value?.sub === canonicalSub) mcpKeys.push(key);
      }
    }
  }
  if (env.MCP_INBOX) await env.MCP_INBOX.getByName(mcpHash).purge();
  if (env.ADMIN_DB) {
    await env.ADMIN_DB.prepare("DELETE FROM usage_events WHERE user_key = ?").bind(usageHash).run();
    await env.ADMIN_DB.prepare("DELETE FROM users_first_seen WHERE user_key = ?").bind(usageHash).run();
    // Which problems this account hit (the dashboard's "affected people").
    await env.ADMIN_DB.prepare("DELETE FROM app_error_users WHERE user_key = ?").bind(usageHash).run();
  }

  const devices = await env.STUDIQUO_DATA.get(`chat:devices:${chatKey}`, "json") ?? [];

  const deletionKeys = [
    ...checkpointKeys, ...ownedSessionKeys, ...accountKeys, ...ownedCredentialKeys, ...ownedPasskeyUserKeys, ...mcpKeys,
    ...emails.flatMap(email => [`email-account-owner:${email}`, `email-accounts:${email}`]),
    ...[...identityKeys].map(key => `identity-canonical:${key}`),
    ...ownedTokenHashes.flatMap(hash => [`snapshot:${hash}`, `actions:${hash}`]),
    `snapshot:${mcpHash}`, `chat:user:${chatKey}`, `chat:devices:${chatKey}`,
    ...devices.map(device => `chat:device-owner:${device.token}`),
  ];
  if (chatUser) deletionKeys.push(`chat:code:${chatUser.code}`, `chat:linktoken:${chatUser.linkToken}`, `chat:avatar:${chatUser.code}`);
  await env.STUDIQUO_DATA.put(deletionStateKey, JSON.stringify({ status: "deleting", deletionKeys: [...new Set(deletionKeys)] }));
  await deleteKeys(env, deletionKeys);
  await env.STUDIQUO_DATA.put(deletionStateKey, JSON.stringify({ status: "deleted" }));
  return { deleted: true };
}
