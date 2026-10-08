import { sha256Hex } from "./auth.js";
import { queueRevenueCatDeletion } from "./privacy-retention.js";

// How long the retired password generation outlives the deletion. KV can serve
// a stale record for about a minute; a week is a wide margin on top of that.
const ACCOUNT_GENERATION_RETIREMENT_SECONDS = 7 * 86_400;

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
  let previousState = await env.STUDIQUO_DATA.get(deletionStateKey, "json");
  const jobKey = `privacy-account-delete:${await sha256Hex(canonicalSub)}`;
  if (previousState?.status === "deleted") {
    await env.STUDIQUO_DATA.delete(jobKey);
    return { deleted: true };
  }
  if (previousState?.status === "active") {
    // The person signed in again after the earlier deletion finished (see
    // mintSession), so there is a new account. A request made since then
    // wrote its job after that moment; a job from before it (or one that has
    // already been cleared) is a leftover of the earlier deletion — a retry
    // that read it just before the person came back — and running it would
    // erase the new account. A marker without a usable time can't tell the
    // two apart, and then the person's own request wins.
    const startedAt = previousState.reregisteredAt;
    const isRequestedSince = job => Number.isFinite(startedAt) ? job?.requestedAt >= startedAt : true;
    let job = await env.STUDIQUO_DATA.get(jobKey, "json");
    if (!isRequestedSince(job)) {
      // Read once more before clearing: the person may have asked to delete
      // the new account in the meantime, and that job must not be removed.
      job = await env.STUDIQUO_DATA.get(jobKey, "json");
      if (!isRequestedSince(job)) {
        if (job) await env.STUDIQUO_DATA.delete(jobKey);
        return { deleted: true };
      }
    }
    // The earlier account's checkpoint does not describe this one.
    previousState = null;
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

  // Per-account state kept in RATE_COUNTER objects is named by a hash of the
  // email: where it was signed in from, recent failures, the notice allowance,
  // code-attempt counters, and the password generation.
  //
  // The generation is retired FIRST, before anything is deleted. A legacy-password
  // upgrade (local-auth.js) that began before this deletion — or whose login read
  // a stale copy of the record afterwards — would otherwise write account:local:*
  // back once it is gone; moving the count on makes that write refuse. It isn't
  // dropped outright for that reason: its own alarm clears it after
  // ACCOUNT_GENERATION_RETIREMENT_SECONDS.
  const privacyEmails = new Set([
    ...emails,
    ...accountKeys.filter(key => key.startsWith("account:local:")).map(key => key.slice("account:local:".length)),
  ].map(email => String(email).trim().toLowerCase()).filter(Boolean));
  if (env.RATE_COUNTER) {
    for (const email of privacyEmails) {
      await env.RATE_COUNTER.getByName(`account-gen:${await sha256Hex(email)}`).retireAccountGeneration(ACCOUNT_GENERATION_RETIREMENT_SECONDS);
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
    ...emails.flatMap(email => [`email-account-owner:${email}`, `email-accounts:${email}`, `email-verify:${email}`]),
    ...[...identityKeys].map(key => `identity-canonical:${key}`),
    ...ownedTokenHashes.flatMap(hash => [`snapshot:${hash}`, `actions:${hash}`]),
    `snapshot:${mcpHash}`, `chat:user:${chatKey}`, `chat:devices:${chatKey}`,
    ...devices.map(device => `chat:device-owner:${device.token}`),
  ];
  if (chatUser) deletionKeys.push(`chat:code:${chatUser.code}`, `chat:linktoken:${chatUser.linkToken}`, `chat:avatar:${chatUser.code}`);
  await env.STUDIQUO_DATA.put(deletionStateKey, JSON.stringify({ ...checkpoint, deletionKeys: [...new Set(deletionKeys)] }));
  await deleteKeys(env, deletionKeys);

  // The rest of the per-account RATE_COUNTER state goes only after the account
  // itself is gone, so a Durable Object hiccup here can't hold the real
  // deletion up: it just leaves the job un-"deleted", and the retry (the job
  // record is still there) repeats these idempotent calls. Not reachable: the
  // per-IP failure counters, keyed by a hash of IP+email so the IPs can't be
  // listed; they expire on their own within about two weeks.
  if (env.RATE_COUNTER) {
    for (const email of privacyEmails) {
      const emailHash = await sha256Hex(email);
      for (const name of ["login-seen", "login-fail-account", "login-notice", "email-code-send", "email-code-confirm"]) {
        await env.RATE_COUNTER.getByName(`${name}:${emailHash}`).purgeAll();
      }
    }
  }

  await env.STUDIQUO_DATA.put(deletionStateKey, JSON.stringify({ status: "deleted", identityKeys: [...identityKeys] }));
  await env.STUDIQUO_DATA.delete(jobKey);
  return { deleted: true };
}
