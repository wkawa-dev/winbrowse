import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import worker from "../src/index.js";

const migration = new URL("../migrations/0001_breakage_reports.sql", import.meta.url);

const report = () => ({
  url: "https://shop.example/cart",
  appVersion: "1.0.1 (7)",
  system: "iOS 26.1, iPhone",
  userAgent: "UA",
  desktopSite: false,
  protections: ["network"],
  rulesets: ["easylist"],
  filterListVersion: "2026-11-01",
  extensions: [],
  compile: null,
  errors: [],
  created: "2026-11-11T10:00:00Z",
  token: "not stored",
});

function environment({ allowed = true, keys = [] } = {}) {
  const db = new DatabaseSync(":memory:");
  db.exec(readFileSync(migration, "utf8"));
  const REPORTS = {
    prepare(sql) {
      const statement = db.prepare(sql);
      let values = [];
      return {
        bind(...args) {
          values = args;
          return this;
        },
        run() {
          statement.run(...values);
          return { success: true };
        },
      };
    },
  };
  const ASSETS = { fetch: async () => new Response("static file") };
  const REPORT_LIMIT = {
    limit: async (options) => {
      keys.push(options.key);
      return { success: allowed };
    },
  };
  return { db, keys, env: { REPORTS, ASSETS, REPORT_LIMIT } };
}

const post = (env, body, type = "application/json") =>
  worker.fetch(new Request("https://winbrowse.example/api/reports", { method: "POST", headers: type ? { "content-type": type } : {}, body }), env);

test("stores a valid report and answers 201 with its id", async () => {
  const { db, env } = environment();
  const response = await post(env, JSON.stringify(report()));
  assert.equal(response.status, 201);
  const { id } = await response.json();
  assert.match(id, /^[0-9a-f-]{36}$/);
  const [row] = db.prepare("SELECT id, site, app_version, system, report FROM breakage_reports").all();
  assert.equal(row.id, id);
  assert.equal(row.site, "shop.example");
  assert.equal(row.app_version, "1.0.1 (7)");
  assert.equal(row.report.includes("not stored"), false);
});

test("answers 429 to a client over its limit, before reading the body, and stores nothing", async () => {
  const { db, keys, env } = environment({ allowed: false });
  const response = await worker.fetch(new Request("https://winbrowse.example/api/reports", {
    method: "POST",
    headers: { "content-type": "application/json", "cf-connecting-ip": "192.0.2.7" },
    body: JSON.stringify(report()),
  }), env);
  assert.equal(response.status, 429);
  assert.equal(response.headers.get("retry-after"), "60");
  assert.deepEqual(keys, ["192.0.2.7"]);
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM breakage_reports").get().n, 0);
});

test("refuses what the intake cannot store, and stores nothing", async () => {
  const { db, env } = environment();
  assert.equal((await post(env, "{")).status, 400);
  assert.equal((await post(env, JSON.stringify(report()), "text/plain")).status, 415);
  assert.equal((await post(env, "x".repeat(256 * 1024 + 1))).status, 413);
  assert.equal((await post(env, JSON.stringify({ ...report(), url: "file:///etc/hosts" }))).status, 400);
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM breakage_reports").get().n, 0);
});

test("answers other methods on the report path and serves every other path from the assets", async () => {
  const { env } = environment();
  const get = await worker.fetch(new Request("https://winbrowse.example/api/reports"), env);
  assert.equal(get.status, 405);
  assert.equal(get.headers.get("allow"), "POST");
  assert.equal(await (await worker.fetch(new Request("https://winbrowse.example/index.html"), env)).text(), "static file");
});
