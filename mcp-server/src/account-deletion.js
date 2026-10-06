import { sha256Hex } from "./auth.js";
import { queueRevenueCatDeletion } from "./privacy-retention.js";

// Once accepted, cleanup survives session revocation and request timeouts.
export async function startAccountDeletion(env, canonicalSub) {
  const jobKey = `privacy-account-delete:${await sha256Hex(canonicalSub)}`;
  await env.STUDIQUO_DATA.put(jobKey, JSON.stringify({ canonicalSub, requestedAt: Date.now() }));
  try {
    await deleteAccount(env, canonicalSub);
    return { deleted: true, externalDeletionPending: true };
  } catch {
    return { deleted: false, cleanupPending: true };
  }
}

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
  const jobKey = `privacy-account-delete:${await sha256Hex(canonicalSub)}`;
  if (previousState?.status === "deleted") {
    await env.STUDIQUO_DATA.delete(jobKey);
    return { deleted: true };
  }
  await env.STUDIQUO_DATA.put(jobKey, JSON.stringify({ canonicalSub, requestedAt: Date.now() }));
  const checkpointKeys = new Set(previousState?.deletionKeys ?? []);
  let checkpoint = { ...previousState, status: "deleting", deletionKeys: [...checkpointKeys] };
  await env.STUDIQUO_DATA.put(deletionStateKey, JSON.stringify(checkpoint));

  const ownerKeys = await entries(env, "email-account-owner:");
  const emails = [...(previousState?.emails ?? [])];
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

  const identityKeys = new Set([canonicalSub, ...(previousState?.identityKeys ?? [])]);
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
  const ownedTokenHashes = [...(previousState?.tokenHashes ?? [])];
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
  checkpoint = { status: "deleting", deletionKeys: [...checkpointKeys], emails, identityKeys: [...identityKeys], tokenHashes: [...new Set(ownedTokenHashes)] };
  await env.STUDIQUO_DATA.put(deletionStateKey, JSON.stringify(checkpoint));
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

  // A legacy-password upgrade (local-auth.js) that began before this deletion
  // — or whose login read a stale copy of the record afterwards — would
  // otherwise write account:local:* back once it is gone. Moving the account's
  // generation on first makes that write refuse. Bumped, never reset: a
  // lower number would let an old record's generation match again.
  if (env.RATE_COUNTER) {
    const localEmails = new Set(accountKeys
      .filter(key => key.startsWith("account:local:"))
      .map(key => key.slice("account:local:".length).trim().toLowerCase()));
    for (const email of localEmails) {
      await env.RATE_COUNTER.getByName(`account-gen:${await sha256Hex(email)}`).nextAccountGeneration();
    }
  }

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
    for (const identity of identityKeys) {
      const accountKey = await sha256Hex(`usage-account:${identity}`);
      await env.ADMIN_DB.prepare("INSERT OR IGNORE INTO privacy_deleted_customers (customer_hash, deleted_at) VALUES (?, ?)")
        .bind(await sha256Hex(identity), Date.now()).run();
      await queueRevenueCatDeletion(env, identity);
      await env.ADMIN_DB.prepare("DELETE FROM subscribers WHERE app_user_id = ?").bind(identity).run();
      await env.ADMIN_DB.prepare("DELETE FROM revenuecat_events WHERE app_user_id = ?").bind(identity).run();
      await env.ADMIN_DB.prepare("DELETE FROM app_error_users WHERE user_key = ?").bind(accountKey).run();
      const reports = await env.ADMIN_DB.prepare("SELECT id FROM issue_reports WHERE account_key = ? OR reporter_key IN (SELECT value FROM json_each(?))")
        .bind(accountKey, JSON.stringify(ownedTokenHashes)).all();
      for (const report of reports.results ?? []) {
        checkpointKeys.add(`issue-report:${report.id}`);
        checkpointKeys.add(`issue-report-screenshot:${report.id}`);
      }
      // Save image ownership before removing the D1 mirror, including images
      // whose KV report expired or was only partially persisted.
      await env.STUDIQUO_DATA.put(deletionStateKey, JSON.stringify({ ...checkpoint, deletionKeys: [...checkpointKeys] }));
      await env.ADMIN_DB.prepare("DELETE FROM issue_reports WHERE account_key = ?")
        .bind(accountKey).run();
    }
    for (const tokenHash of ownedTokenHashes) {
      await env.ADMIN_DB.prepare("DELETE FROM issue_reports WHERE reporter_key = ?").bind(tokenHash).run();
    }
  }

  // KV also covers historical reports whose dashboard mirror failed. The
  // durable checkpoint preserves legacy token ownership after revocation.
  const accountHashes = new Set(await Promise.all([...identityKeys].map(identity => sha256Hex(`usage-account:${identity}`))));
  for (const reportKey of await entries(env, "issue-report:")) {
    const report = await env.STUDIQUO_DATA.get(reportKey, "json");
    if (!accountHashes.has(report?.accountKey) && !ownedTokenHashes.includes(report?.reporterKey)) continue;
    checkpointKeys.add(reportKey);
    checkpointKeys.add(`issue-report-screenshot:${reportKey.slice("issue-report:".length)}`);
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
  await env.STUDIQUO_DATA.put(deletionStateKey, JSON.stringify({ ...checkpoint, deletionKeys: [...new Set(deletionKeys)] }));
  await deleteKeys(env, deletionKeys);
  await env.STUDIQUO_DATA.put(deletionStateKey, JSON.stringify({ status: "deleted", identityKeys: [...identityKeys] }));
  await env.STUDIQUO_DATA.delete(jobKey);
  return { deleted: true };
}
