// The drill's synthetic people and what they do, always through the Worker's public
// routes. `prepareBackupPoint` runs before the backup is taken; `applyRevocations`
// and `createPostBackupActivity` after it.
//
// Everyone signs up with e-mail and password, so Apple and Google (which the Worker
// would have to verify against the providers) are not needed, and no KV is seeded.
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { HarnessFailure, type HttpResult, type OutboundGuard, type SyntheticSecrets, type WorkerInstance } from './runtime.ts';
import { redact, sha256 } from './lib.ts';
import { createSoftwarePasskey, type SoftwarePasskey } from './webauthn.ts';

export const PRODUCT_PRO = 'com.yabuko.studiquo.pro.yearly';
export const PRODUCT_PLUS = 'com.yabuko.studiquo.plus.yearly';
const REDIRECT_URI = 'https://client.drill.invalid/callback';
const YEAR_MS = 365 * 24 * 3_600_000;

export interface Account {
  label: string;
  email: string;
  password: string;
  ip: string;
  sub: string;
  token: string;
  chatKey: string;
  code?: string;
  linkToken?: string;
  /** Set when the password was replaced or the account begun again after the backup. */
  newPassword?: string;
  newToken?: string;
}

export interface McpClient {
  clientId: string;
  clientName: string;
  accessToken: string;
  refreshToken: string;
  /** The refresh token that replaced this one, when it was exchanged after the backup. */
  rotatedTo?: string;
}

export interface World {
  guard: OutboundGuard;
  secrets: SyntheticSecrets;
  accounts: Record<string, Account>;
  rooms: Record<string, string>;
  messages: Record<string, number>;
  markers: Record<string, string>;
  attachments: Record<string, string>;
  mcp: Record<string, McpClient>;
  reports: Record<string, string>;
  passkeys: Record<string, SoftwarePasskey>;
  libraryIds: Record<string, string>;
  documentRoom: string;
  issueReportId: string;
  /** Every credential and address made for this run: reports must contain none of them. */
  sensitive: Set<string>;
}

export const ACCOUNT_LABELS = ['A', 'P', 'Q', 'B', 'C', 'D', 'E', 'F', 'F2', 'G', 'H', 'I', 'I2', 'J', 'JR'] as const;

export function createWorld(guard: OutboundGuard, secrets: SyntheticSecrets): World {
  return {
    guard, secrets, accounts: {}, rooms: {}, messages: {}, markers: {}, attachments: {}, mcp: {}, reports: {}, passkeys: {}, libraryIds: {},
    documentRoom: '', issueReportId: '', sensitive: new Set(),
  };
}

/** Fails the setup (not the drill's result) when a step the drill relies on did not work. */
function expectStatus(result: HttpResult, label: string, ...allowed: number[]) {
  if (!allowed.includes(result.status)) throw new HarnessFailure(`Setup step "${label}" answered ${result.status}: ${redact(result.text)}`);
  return result;
}

const remember = (world: World, ...values: (string | undefined)[]) => { for (const value of values) if (value) world.sensitive.add(value); };

export async function requestEmailCode(w: WorkerInstance, world: World, email: string, ip: string) {
  world.guard.state.codes.delete(email);
  const sent = await w.call('/api/auth/email/send-code', { json: { email }, ip });
  const code = world.guard.state.codes.get(email);
  return { status: sent.status, code };
}

/** Sign-up, reset and re-registration are one route: prove the mailbox and set a password. */
export async function confirmEmailCode(w: WorkerInstance, world: World, email: string, password: string, ip: string) {
  const { status, code } = await requestEmailCode(w, world, email, ip);
  if (status !== 200 || !code) return { status, token: undefined as string | undefined };
  const confirmed = await w.call('/api/auth/email/confirm-code', { json: { email, code, password }, ip });
  remember(world, password, confirmed.json?.token);
  return { status: confirmed.status, token: confirmed.json?.token as string | undefined };
}

async function signUp(w: WorkerInstance, world: World, label: string, index: number): Promise<Account> {
  const email = `drill-${label.toLowerCase()}-${randomBytes(6).toString('hex')}@drill.invalid`;
  const password = randomBytes(18).toString('base64url');
  const ip = `203.0.113.${index + 1}`;
  remember(world, email, password);
  const { status, token } = await confirmEmailCode(w, world, email, password, ip);
  if (status !== 200 || !token) throw new HarnessFailure(`Sign-up of ${label} answered ${status}`);
  const sub = `email:${email}`;
  const account: Account = { label, email, password, ip, sub, token, chatKey: sha256(`chat-account:${sub}`) };
  world.accounts[label] = account;
  return account;
}

async function joinChat(w: WorkerInstance, account: Account) {
  const me = expectStatus(await w.call('/api/chat/me', { token: account.token, json: { name: `Drill ${account.label}` } }), `chat profile ${account.label}`, 200);
  account.code = me.json.code;
  account.linkToken = me.json.linkToken;
}

async function befriend(w: WorkerInstance, world: World, roomName: string, first: Account, second: Account) {
  const added = expectStatus(await w.call('/api/chat/friends/link-add', { token: first.token, json: { token: second.linkToken } }), `friend ${roomName}`, 200);
  world.rooms[roomName] = added.json.roomID;
  return added.json.roomID as string;
}

async function sendMessage(w: WorkerInstance, world: World, account: Account, roomName: string, name: string) {
  const text = `drill-message-${name}-${randomBytes(6).toString('hex')}`;
  const sent = expectStatus(await w.call(`/api/chat/rooms/${world.rooms[roomName]}/messages`, { token: account.token, json: { text } }), `message ${name}`, 200);
  world.messages[name] = sent.json.id;
  world.markers[name] = text;
}

async function uploadAttachment(w: WorkerInstance, world: World, account: Account, roomName: string, name: string) {
  const uploaded = expectStatus(await w.call(`/api/chat/rooms/${world.rooms[roomName]}/attachments`, {
    token: account.token, json: { contentType: 'image/png', data: randomBytes(32).toString('base64') },
  }), `attachment ${name}`, 201);
  world.attachments[name] = uploaded.json.id;
}

async function syncSnapshot(w: WorkerInstance, world: World, account: Account) {
  const marker = `drill-notebook-${account.label}-${randomBytes(6).toString('hex')}`;
  world.markers[`notebook:${account.label}`] = marker;
  expectStatus(await w.call('/api/snapshot', {
    method: 'PUT', token: account.token,
    json: { version: 1, notebooks: [{ id: `drill-${account.label}`, title: marker, tags: [], pages: [] }], flashcardDecks: [], calendarEvents: [], folders: [] },
  }), `snapshot ${account.label}`, 200);
}

export async function webhook(w: WorkerInstance, world: World, type: string, appUserId: string, productId: string, extra: Record<string, unknown> = {}) {
  return w.call('/api/admin/revenuecat-webhook', {
    headers: { authorization: world.secrets.webhookSecret },
    json: {
      event: {
        id: randomUUID(), type, app_user_id: appUserId, product_id: productId, environment: 'PRODUCTION',
        event_timestamp_ms: Date.now(), expiration_at_ms: Date.now() + YEAR_MS, original_transaction_id: `drill-${sha256(appUserId).slice(0, 24)}`, ...extra,
      },
    },
  });
}

async function purchase(w: WorkerInstance, world: World, account: Account, productId: string) {
  const answer = expectStatus(await webhook(w, world, 'INITIAL_PURCHASE', account.sub, productId), `purchase ${account.label}`, 200);
  if (answer.json?.ignored) throw new HarnessFailure(`Purchase of ${account.label} was ignored`);
}

/** The whole OAuth pairing an AI app goes through, with a PKCE verifier of its own. */
async function connectMcpClient(w: WorkerInstance, account: Account, clientName: string): Promise<McpClient> {
  const registered = expectStatus(await w.call('/oauth/register', { json: { client_name: clientName, redirect_uris: [REDIRECT_URI] } }), 'oauth register', 201);
  const clientId = registered.json.client_id as string;
  const verifier = randomBytes(40).toString('base64url');
  const challenge = createHash('sha256').update(verifier).digest('base64url');
  const query = new URLSearchParams({ client_id: clientId, redirect_uri: REDIRECT_URI, response_type: 'code', code_challenge: challenge, code_challenge_method: 'S256', scope: 'studiquo.read studiquo.write' });
  const page = expectStatus(await w.call(`/oauth/authorize?${query}`), 'oauth authorize', 200);
  const flow = /id:'([a-f0-9]{64})'/.exec(page.text)?.[1];
  if (!flow) throw new HarnessFailure('The OAuth authorize page did not name its flow');
  const issued = expectStatus(await w.call('/api/mcp/pairing-code', { token: account.token, json: { kind: 'other' } }), 'pairing code', 200);
  const paired = expectStatus(await w.call('/oauth/pair', { json: { id: flow, code: issued.json.code } }), 'oauth pair', 200);
  const code = new URL(paired.json.redirect).searchParams.get('code');
  if (!code) throw new HarnessFailure('The OAuth pairing returned no code');
  const tokens = expectStatus(await w.call('/oauth/token', {
    form: { grant_type: 'authorization_code', code, client_id: clientId, redirect_uri: REDIRECT_URI, code_verifier: verifier },
  }), 'oauth token', 200);
  return { clientId, clientName, accessToken: tokens.json.access_token, refreshToken: tokens.json.refresh_token };
}

async function registerPasskey(w: WorkerInstance, world: World, account: Account): Promise<SoftwarePasskey> {
  const token = account.token;
  world.guard.state.codes.delete(account.email);
  expectStatus(await w.call('/api/passkeys/email-code/send', { token, json: { email: account.email } }), 'passkey code', 200);
  const code = world.guard.state.codes.get(account.email);
  if (!code) throw new HarnessFailure('No passkey e-mail code was captured');
  expectStatus(await w.call('/api/passkeys/email-code/confirm', { token, json: { email: account.email, code } }), 'passkey confirm', 200);
  const options = expectStatus(await w.call('/api/passkeys/register/options', { token, json: { email: account.email } }), 'passkey options', 200);
  const passkey = createSoftwarePasskey();
  expectStatus(await w.call('/api/passkeys/register/verify', {
    token, json: { transaction: options.json.transaction, credential: passkey.registrationResponse(options.json.options.challenge) },
  }), 'passkey register', 200);
  return passkey;
}

export function adminHeaders(world: World): Record<string, string> {
  const now = Math.floor(Date.now() / 1000);
  const assertion = world.secrets.signAccessJwt({
    iss: `https://${world.secrets.accessHost}`, aud: world.secrets.accessAudience, sub: 'drill-operator', email: 'operator@drill.invalid', iat: now, exp: now + 3_600,
  });
  return { 'cf-access-jwt-assertion': assertion };
}

async function reportIdFor(w: WorkerInstance, world: World, roomName: string, message: string) {
  const list = expectStatus(await w.call('/api/admin/chat-reports?status=all', { headers: adminHeaders(world) }), 'report list', 200);
  const found = (list.json.reports as { id: string; roomID: string; messageID: number }[])
    .find(item => item.roomID === world.rooms[roomName] && item.messageID === world.messages[message]);
  if (!found) throw new HarnessFailure(`The report on ${message} was not listed`);
  return found.id;
}

async function fileReport(w: WorkerInstance, world: World, reporter: Account, roomName: string, message: string, name: string) {
  expectStatus(await w.call(`/api/chat/rooms/${world.rooms[roomName]}/messages/${world.messages[message]}/report`, { token: reporter.token, json: { reason: 'drill' } }), `report ${name}`, 200);
  world.reports[name] = await reportIdFor(w, world, roomName, message);
}

export async function queuedDeletions(w: WorkerInstance) {
  const counts = await Promise.all(['privacy-account-delete:', 'privacy-rc-delete:'].map(async prefix => (await w.kv.list({ prefix })).keys.length));
  return counts[0] + counts[1];
}

/** Runs the hourly job until nothing is queued. Each run takes two jobs of each kind. */
export async function runCronUntilDrained(w: WorkerInstance) {
  for (let run = 0; run < 30; run++) {
    const outcome = await w.cron();
    if (outcome !== 'ok') throw new HarnessFailure(`The scheduled handler answered ${outcome}`);
    if (await queuedDeletions(w) === 0) return;
  }
  throw new HarnessFailure('Queued deletions did not drain');
}

async function deleteAccount(w: WorkerInstance, account: Account) {
  const answer = expectStatus(await w.call('/api/account', { method: 'DELETE', token: account.token, json: { confirmation: 'DELETE' } }), `deletion of ${account.label}`, 200, 202);
  if (answer.json?.cleanupPending) throw new HarnessFailure(`Deletion of ${account.label} is still pending`);
}

/** Everything that exists at the backup point. */
export async function prepareBackupPoint(w: WorkerInstance, world: World) {
  let index = 0;
  for (const label of ACCOUNT_LABELS) await signUp(w, world, label, index++);
  const { A, P, Q, B, E, F, F2, G, H, I, I2, JR } = world.accounts;

  for (const account of [A, P, Q, B, F, F2, G, JR]) await joinChat(w, account);
  await befriend(w, world, 'AP', A, P);
  await befriend(w, world, 'BP', B, P);
  await befriend(w, world, 'FP', F, P);
  await befriend(w, world, 'F2P', F2, P);
  await befriend(w, world, 'GP', G, P);
  await befriend(w, world, 'GQ', G, Q);
  await sendMessage(w, world, A, 'AP', 'A');
  await sendMessage(w, world, B, 'BP', 'B');
  await uploadAttachment(w, world, B, 'BP', 'B');
  await sendMessage(w, world, F, 'FP', 'F');
  await sendMessage(w, world, F2, 'F2P', 'F2');
  await sendMessage(w, world, G, 'GP', 'G1');
  await sendMessage(w, world, G, 'GP', 'G2');
  await uploadAttachment(w, world, G, 'GP', 'G');
  await fileReport(w, world, P, 'FP', 'F', 'F');
  await fileReport(w, world, P, 'F2P', 'F2', 'F2');
  await fileReport(w, world, P, 'GP', 'G2', 'G2');

  for (const account of [A, B, E]) await syncSnapshot(w, world, account);
  world.mcp.A = await connectMcpClient(w, A, 'Drill A');
  world.mcp.B = await connectMcpClient(w, B, 'Drill B');
  world.mcp.E = await connectMcpClient(w, E, 'Drill E');
  world.mcp.E2 = await connectMcpClient(w, P, 'Drill E rotation');
  for (const client of Object.values(world.mcp)) remember(world, client.accessToken, client.refreshToken);

  const inboxMarker = `drill-inbox-${randomBytes(6).toString('hex')}`;
  world.markers.inboxB = inboxMarker;
  expectStatus(await w.call('/mcp', {
    token: world.mcp.B.accessToken, headers: { accept: 'application/json, text/event-stream' },
    json: { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'create_document', arguments: { title: inboxMarker, body: 'synthetic', folderPath: '' } } },
  }), 'inbox item', 200);

  world.documentRoom = randomBytes(32).toString('hex');
  const documentMarker = `drill-document-${randomBytes(6).toString('hex')}`;
  world.markers.documentB = documentMarker;
  expectStatus(await w.call(`/api/document/rooms/${world.documentRoom}/init`, { token: B.token, json: { blocks: [{ order: 0, kind: 'paragraph', text: documentMarker }] } }), 'document room', 200);

  expectStatus(await w.call('/api/usage-events', { method: 'POST', token: B.token }), 'usage event', 200);
  const issue = expectStatus(await w.call('/api/issue-reports', {
    token: B.token, json: { description: 'drill report', screenshot: { contentType: 'image/png', data: randomBytes(32).toString('base64') } },
  }), 'issue report', 200);
  world.issueReportId = issue.json.id;

  for (const label of ['A', 'B'] as const) {
    const id = expectStatus(await w.call('/api/account/library-id', { token: world.accounts[label].token }), `library id ${label}`, 200);
    world.libraryIds[label] = id.json.libraryID;
    remember(world, id.json.libraryID);
  }

  await purchase(w, world, B, PRODUCT_PLUS);
  await purchase(w, world, H, PRODUCT_PRO);
  await purchase(w, world, JR, PRODUCT_PLUS);

  world.passkeys.I = await registerPasskey(w, world, I);
  world.passkeys.I2 = await registerPasskey(w, world, I2);

  // Deleted before the backup, with the provider's DELETE still queued: the hourly
  // job has not run yet when the backup is taken.
  await deleteAccount(w, JR);

  for (const account of Object.values(world.accounts)) {
    if (account === JR) continue;
    expectStatus(await w.call('/api/plan', { token: account.token }), `token of ${account.label} at the backup point`, 200);
  }
}

export type KvExport = { name: string; value: string; expiration?: number; metadata?: unknown }[];

/** A key-by-key export, the way a script over the KV API would make one. Values here are all text. */
export async function exportKv(w: WorkerInstance): Promise<KvExport> {
  const entries: KvExport = [];
  let cursor: string | undefined;
  do {
    const page = await w.kv.list({ cursor });
    for (const key of page.keys) {
      const value = await w.kv.get(key.name, 'text');
      if (value !== null) entries.push({ name: key.name, value, expiration: key.expiration, metadata: key.metadata });
    }
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
  return entries;
}

/** Everything that is taken away after the backup point. */
export async function applyRevocations(w: WorkerInstance, world: World) {
  const { B, C, D, E, F, F2, G, H, I, I2, J, JR } = world.accounts;

  expectStatus(await w.call('/api/session/revoke', { method: 'POST', token: C.token }), 'logout', 200);

  const reset = await confirmEmailCode(w, world, D.email, randomBytes(18).toString('base64url'), D.ip);
  if (reset.status !== 200 || !reset.token) throw new HarnessFailure(`Password reset answered ${reset.status}`);
  D.newToken = reset.token;
  D.newPassword = [...world.sensitive].at(-2);

  const connections = expectStatus(await w.call('/api/mcp/connections', { token: E.token }), 'connections', 200);
  const connection = (connections.json as { id: string; clientName: string }[]).find(item => item.clientName === world.mcp.E.clientName);
  if (!connection) throw new HarnessFailure('The connection to revoke was not listed');
  expectStatus(await w.call(`/api/mcp/connections/${connection.id}`, { method: 'DELETE', token: E.token }), 'revoke connection', 200);
  const rotated = expectStatus(await w.call('/oauth/token', {
    form: { grant_type: 'refresh_token', refresh_token: world.mcp.E2.refreshToken, client_id: world.mcp.E2.clientId },
  }), 'refresh rotation', 200);
  world.mcp.E2.rotatedTo = rotated.json.refresh_token;
  remember(world, rotated.json.refresh_token, rotated.json.access_token);

  const admin = adminHeaders(world);
  expectStatus(await w.call('/api/admin/accounts/suspend', { headers: admin, json: { reportID: world.reports.F, scope: 'account' } }), 'suspend account', 200);
  expectStatus(await w.call('/api/admin/accounts/suspend', { headers: admin, json: { reportID: world.reports.F2, scope: 'chat' } }), 'suspend chat', 200);

  expectStatus(await w.call(`/api/chat/rooms/${world.rooms.GP}/messages/${world.messages.G1}/cancel`, { method: 'POST', token: G.token }), 'cancel message', 200);
  expectStatus(await w.call(`/api/admin/chat-reports/${world.reports.G2}/remove-message`, { headers: admin, json: {} }), 'operator removal', 200);
  expectStatus(await w.call(`/api/chat/friends/${world.accounts.P.code}`, { method: 'DELETE', token: G.token }), 'friend removal', 200);
  expectStatus(await w.call(`/api/chat/rooms/${world.rooms.GQ}/block`, { method: 'POST', token: G.token }), 'block', 200);

  expectStatus(await webhook(w, world, 'EXPIRATION', H.sub, PRODUCT_PRO, { expiration_at_ms: Date.now() - 1_000 }), 'subscription end', 200);

  const reauth = expectStatus(await w.call('/api/passkeys/reauth/options', { token: I.token, json: { action: 'remove-passkeys' } }), 'passkey reauth options', 200);
  expectStatus(await w.call('/api/passkeys/reauth/verify', {
    token: I.token, json: { transaction: reauth.json.transaction, credential: world.passkeys.I.assertionResponse(reauth.json.options.challenge) },
  }), 'passkey reauth verify', 200);
  expectStatus(await w.call('/api/passkeys/remove-all', { method: 'POST', token: I.token }), 'passkey removal', 200);
  const passkeyReset = await confirmEmailCode(w, world, I2.email, randomBytes(18).toString('base64url'), I2.ip);
  if (passkeyReset.status !== 200 || !passkeyReset.token) throw new HarnessFailure(`Passkey-account reset answered ${passkeyReset.status}`);
  I2.newToken = passkeyReset.token;

  await deleteAccount(w, B);
  await deleteAccount(w, J);
  await runCronUntilDrained(w);

  // Both come back as new accounts of the same identity.
  for (const account of [J, JR]) {
    const password = randomBytes(18).toString('base64url');
    const again = await confirmEmailCode(w, world, account.email, password, account.ip);
    if (again.status !== 200 || !again.token) throw new HarnessFailure(`Re-registration of ${account.label} answered ${again.status}`);
    account.newToken = again.token;
    account.newPassword = password;
    expectStatus(await webhook(w, world, 'INITIAL_PURCHASE', account.sub, PRODUCT_PRO), `purchase after re-registration ${account.label}`, 200);
  }
}

/** Work done after the backup that has nothing to do with any revocation. */
export async function createPostBackupActivity(w: WorkerInstance, world: World) {
  const { A } = world.accounts;
  const K = await signUp(w, world, 'K', ACCOUNT_LABELS.length);
  await joinChat(w, K);
  await befriend(w, world, 'AK', A, K);
  await sendMessage(w, world, K, 'AK', 'K');
  await sendMessage(w, world, A, 'AP', 'A-after-backup');
  await syncSnapshot(w, world, K);
  await purchase(w, world, K, PRODUCT_PRO);
}
