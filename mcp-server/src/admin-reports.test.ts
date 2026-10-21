import assert from "node:assert/strict";
import test from "node:test";
import { handleAdminReports } from "./admin-reports.ts";
import { partialEnv, type Untyped } from "./test-env.ts";

function makeAdminEnv() {
  const issueReports = new Map();
  const appErrors = new Map();
  const kv = new Map();

  return partialEnv({
    _issueReports: issueReports,
    _appErrors: appErrors,
    _kv: kv,
    STUDIQUO_DATA: {
      async list({ prefix }: { prefix?: Untyped }) {
        const keys = [...kv.keys()].filter((k) => k.startsWith(prefix)).map((name) => ({ name }));
        return { keys, list_complete: true };
      },
      async get(key: string, type: string) {
        const val = kv.get(key) ?? null;
        return type === "json" && val ? JSON.parse(val) : val;
      },
    },
    ADMIN_DB: {
      prepare(sql: string | string[]) {
        return {
          bind(...args: Untyped[]) {
            return {
              async all() {
                if (sql.includes("FROM issue_reports")) {
                  const status = sql.includes("AND status = ?") ? args[1] : null;
                  const results = [...issueReports.values()].filter((r) => !status || r.status === status);
                  return { results };
                }
                if (sql.includes("FROM app_errors")) {
                  const status = sql.includes("AND e.status = ?") ? args[2] : null;
                  const results = [...appErrors.values()].filter((e) => !status || e.status === status);
                  return { results };
                }
                return { results: [] };
              },
              async first() {
                if (sql.includes("FROM issue_reports WHERE id = ?")) {
                  return issueReports.get(args[0]) ?? null;
                }
                if (sql.includes("FROM app_errors WHERE fingerprint = ?")) {
                  return appErrors.get(args[0]) ?? null;
                }
                return null;
              },
              async run() {
                if (sql.includes("INSERT OR IGNORE INTO issue_reports")) {
                  const id = args[0];
                  if (issueReports.has(id)) return { meta: { changes: 0 } };
                  issueReports.set(id, {
                    id,
                    description: args[3],
                    app_version: args[4],
                    os_version: args[5],
                    device_model: args[6],
                    language: args[7],
                    has_screenshot: args[8],
                    status: "open",
                    admin_note: "",
                    created_at: args[9],
                  });
                  return { meta: { changes: 1 } };
                }
                if (sql.includes("UPDATE issue_reports")) {
                  const [status, note, updatedAt, id] = args;
                  const row = issueReports.get(id);
                  if (row) {
                    if (status !== null) row.status = status;
                    if (note !== null) row.admin_note = note;
                    row.updated_at = updatedAt;
                  }
                  return { meta: { changes: 1 } };
                }
                if (sql.includes("UPDATE app_errors")) {
                  const [status, note, resolvedAfter, updatedAt, fp] = args;
                  const row = appErrors.get(fp);
                  if (row) {
                    if (status !== null) row.status = status;
                    if (note !== null) row.admin_note = note;
                    if (resolvedAfter !== null) row.resolved_after_version = resolvedAfter;
                    row.updated_at = updatedAt;
                  }
                  return { meta: { changes: 1 } };
                }
                return { meta: { changes: 0 } };
              },
            };
          },
        };
      },
    },
  });
}

test("returns null for non-admin-report routes and 503 when ADMIN_DB is missing", async () => {
  const otherUrl = new URL("https://api.studiquo.app/api/announcements");
  assert.equal(await handleAdminReports(otherUrl, new Request(otherUrl), partialEnv({})), null);

  const adminUrl = new URL("https://api.studiquo.app/api/admin/issue-reports");
  const unavailable = await handleAdminReports(adminUrl, new Request(adminUrl), partialEnv({}));
  assert.equal(unavailable!.status, 503);
});

test("lists issue reports with screenshot URL mapping and enforces JSON Content-Type on mutations", async () => {
  const env = makeAdminEnv();
  const id = "11111111-2222-3333-4444-555555555555";
  env._issueReports.set(id, {
    id,
    description: "ペンが反応しない",
    app_version: "1.0 (12)",
    os_version: "iPadOS 18.1",
    device_model: "iPad14,5",
    language: "ja",
    has_screenshot: 1,
    status: "open",
    admin_note: "",
    created_at: Date.now(),
  });

  const listUrl = new URL("https://api.studiquo.app/api/admin/issue-reports?status=open");
  const listRes = await handleAdminReports(listUrl, new Request(listUrl), env);
  assert.equal(listRes!.status, 200);
  const { reports } = await listRes!.json();
  assert.equal(reports.length, 1);
  assert.equal(reports[0].hasScreenshot, true);
  assert.equal(reports[0].screenshotURL, `https://api.studiquo.app/api/issue-reports/${id}/screenshot`);

  const updateUrl = new URL(`https://api.studiquo.app/api/admin/issue-reports/${id}`);
  const formAttempt = await handleAdminReports(
    updateUrl,
    new Request(updateUrl, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: "status=resolved",
    }),
    env
  );
  assert.equal(formAttempt!.status, 415, "must reject non-JSON writes to prevent cross-site form submissions");

  const validUpdate = await handleAdminReports(
    updateUrl,
    new Request(updateUrl, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ status: "in_progress", note: "再現確認中" }),
    }),
    env
  );
  assert.equal(validUpdate!.status, 200);
  assert.equal(env._issueReports.get(id).status, "in_progress");
  assert.equal(env._issueReports.get(id).admin_note, "再現確認中");
});

test("updates app errors and records resolved_after_version when marked resolved", async () => {
  const env = makeAdminEnv();
  const fp = "a".repeat(64);
  env._appErrors.set(fp, {
    fingerprint: fp,
    kind: "crash",
    title: "EXC_BAD_ACCESS",
    detail: "stack",
    first_seen_at: Date.now() - 1000,
    last_seen_at: Date.now(),
    occurrences: 3,
    affected_users: 2,
    last_app_version: "1.0 (15)",
    last_os_version: "18.1",
    last_device_model: "iPad",
    status: "open",
    admin_note: "",
    resolved_after_version: null,
  });

  const url = new URL(`https://api.studiquo.app/api/admin/app-errors/${fp}`);
  const res = await handleAdminReports(
    url,
    new Request(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ status: "resolved", note: "Fixed in build 16" }),
    }),
    env
  );
  assert.equal(res!.status, 200);
  assert.equal(env._appErrors.get(fp).status, "resolved");
  assert.equal(env._appErrors.get(fp).resolved_after_version, "1.0 (15)");
});
