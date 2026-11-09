// Authorization policies, not inferred from the responses under test.
// Public means the endpoint has its own proof/validation (OAuth, webhook,
// email code, report secret); it does not mean every request is accepted.
export type Policy = 'session' | 'access' | 'public';
export interface Route { policy: Policy; method: string; path: string }
export const ROOM = 'a'.repeat(64);
export const UUID = '123e4567-e89b-42d3-a456-426614174000';
export const routes: Route[] = [];
function add(policy: Policy, methods: string, ...paths: string[]) {
  for (const path of paths) for (const method of methods.split(' ')) routes.push({policy, method, path});
}
add('session','DELETE','/api/account','/api/actions', '/api/mcp/connections/synthetic');
add('session','GET','/api/account/library-id','/api/actions','/api/plan','/api/mcp/connections','/api/mcp/inbox');
add('session','POST','/api/session/revoke','/api/session/refresh','/api/mcp/pairing-code','/api/mcp/inbox/synthetic');
add('session','PUT','/api/snapshot');
add('session','POST','/api/ai/chat','/api/ai/grade','/api/ai/review','/api/ai/rubric');
add('session','GET','/api/ai/usage');
add('session','POST','/api/chat/me','/api/chat/me/avatar','/api/chat/friends','/api/chat/friends/link-add','/api/chat/friends/requests/accept','/api/chat/friends/requests/reject');
add('session','GET','/api/chat/friends','/api/chat/friends/blocked','/api/chat/friends/outgoing','/api/chat/friends/requests','/api/chat/inbox', '/api/chat/avatar/ABCDEF');
add('session','DELETE','/api/chat/friends/ABCDEF');
add('session','POST DELETE','/api/chat/devices');
add('session','GET POST',`/api/chat/rooms/${ROOM}/messages`);
add('session','POST',...['read','messages/1/cancel','messages/1/edit','messages/1/report','messages/lookup','attachments','block','unblock'].map(p=>`/api/chat/rooms/${ROOM}/${p}`));
add('session','GET',`/api/chat/rooms/${ROOM}/attachments/${UUID}`,`/api/chat/rooms/${ROOM}/block-status`);
add('session','GET','/api/chat/group-invites','/api/chat/groups');
add('session','POST','/api/chat/groups',...['invites','invites/accept','invites/reject','avatar'].map(p=>`/api/chat/groups/${ROOM}/${p}`));
add('session','PATCH',`/api/chat/groups/${ROOM}`);
add('session','DELETE',`/api/chat/groups/${ROOM}/members/ABCDEF`);
add('session','GET',`/api/chat/groups/${ROOM}/avatar`);
add('session','GET','/api/document/invites',...['participants','state'].map(p=>`/api/document/rooms/${ROOM}/${p}`));
add('session','POST',...['init','invite','invite/accept','invite/decline','leave','propose','changes/1/review'].map(p=>`/api/document/rooms/${ROOM}/${p}`));
add('session','DELETE',`/api/document/rooms/${ROOM}/participants/${ROOM}`);
add('session','GET PUT',`/api/document/rooms/${ROOM}/snapshot`,`/api/document/rooms/${ROOM}/assets/${ROOM}`);
add('session','POST',`/api/document/rooms/${ROOM}/assets/missing`);
add('session','POST',...['register/options','register/verify','remove-all','reauth/options','reauth/verify'].map(p=>`/api/passkeys/${p}`));
add('session','GET','/api/passkeys/status');
add('session','GET POST','/api/rag/consent',`/api/rag/documents/${ROOM}/state`,'/api/rag/pdf/consent');
add('session','GET','/api/rag/status',`/api/rag/sources/${ROOM}/readiness`);
add('session','POST','/api/rag/cleanup','/api/rag/documents/prepare','/api/rag/index','/api/rag/pdf/intakes',`/api/rag/pdf/intakes/${UUID}/process`,`/api/rag/pdf/intakes/${UUID}/cancel`);
add('session','DELETE','/api/rag/source',`/api/rag/sources/${ROOM}`);
add('access','GET','/api/admin/stats','/api/admin/accounts/suspended','/api/admin/audit-log','/api/admin/announcements','/api/admin/app-errors','/api/admin/chat-reports','/api/admin/issue-reports',`/api/admin/chat-reports/${UUID}`);
add('access','POST','/api/admin/accounts/suspend','/api/admin/accounts/unsuspend','/api/admin/announcements','/api/admin/issue-reports/import-legacy',`/api/admin/issue-reports/${UUID}`,`/api/admin/app-errors/${ROOM}`,`/api/admin/chat-reports/${UUID}`,`/api/admin/chat-reports/${UUID}/remove-message`,`/api/admin/chat-reports/${UUID}/warn`,`/api/admin/announcements/${UUID}/push`,`/api/admin/announcements/${UUID}/push-test`);
add('access','PUT DELETE',`/api/admin/announcements/${UUID}`);
add('session','POST','/api/issue-reports','/api/app-errors','/api/usage-events');
add('access','GET',`/api/issue-reports/${UUID}/screenshot`);
add('public','POST','/api/auth/apple','/api/auth/google','/api/auth/email/send-code','/api/auth/email/confirm-code','/api/auth/local/login','/api/attest/challenge','/api/attest/register','/api/admin/revenuecat-webhook',...['email-code/send','email-code/confirm','login/options','login/verify'].map(p=>`/api/passkeys/${p}`),'/oauth/register','/oauth/pair','/oauth/token');
add('public','GET','/api/announcements','/oauth/authorize');
// MCP has its own OAuth scope/transport checks, in addition to the session gate.
add('session','GET POST DELETE','/mcp');
