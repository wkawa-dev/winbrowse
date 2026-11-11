import { test } from "node:test";
import assert from "node:assert/strict";
import { parseReport } from "../src/reports.js";

const sample = () => ({
  url: "https://shop.example/cart",
  appVersion: "1.0.1 (7)",
  system: "iOS 26.1, iPhone",
  userAgent: "Mozilla/5.0",
  desktopSite: false,
  protections: ["network", "cosmetic"],
  rulesets: ["easylist"],
  filterListVersion: "2026-11-01",
  extensions: [{ id: "sponsorblock", version: "5.0", enabled: true }],
  compile: null,
  errors: [{ kind: "error", message: "boom", page: "https://shop.example/cart", source: "https://shop.example/a.js", line: 3, date: "2026-11-11T10:00:00Z" }],
  created: "2026-11-11T10:00:00Z",
});

const text = (value) => JSON.stringify(value);

test("accepts a report and keeps the host as the site", () => {
  const result = parseReport(text(sample()));
  assert.equal(result.ok, true);
  assert.equal(result.site, "shop.example");
  assert.equal(result.appVersion, "1.0.1 (7)");
  assert.equal(result.system, "iOS 26.1, iPhone");
  assert.deepEqual(result.report.protections, ["network", "cosmetic"]);
});

test("drops fields the app does not send", () => {
  const report = { ...sample(), token: "secret", device: { udid: "x" } };
  const result = parseReport(text(report));
  assert.equal(result.ok, true);
  assert.equal("token" in result.report, false);
  assert.equal("device" in result.report, false);
});

test("rejects text that is not JSON", () => {
  assert.deepEqual(parseReport("{"), { ok: false, error: "the report is not valid JSON" });
});

test("rejects a report that is not an object", () => {
  assert.equal(parseReport("[]").ok, false);
  assert.equal(parseReport("null").ok, false);
  assert.equal(parseReport('"text"').ok, false);
});

test("accepts only http and https addresses", () => {
  assert.equal(parseReport(text({ ...sample(), url: "file:///etc/hosts" })).ok, false);
  assert.equal(parseReport(text({ ...sample(), url: "not a url" })).ok, false);
  assert.equal(parseReport(text({ ...sample(), url: "http://plain.example/" })).ok, true);
});

test("rejects wrong types and over-long text", () => {
  assert.equal(parseReport(text({ ...sample(), desktopSite: "yes" })).ok, false);
  assert.equal(parseReport(text({ ...sample(), userAgent: "x".repeat(513) })).ok, false);
  assert.equal(parseReport(text({ ...sample(), protections: "network" })).ok, false);
});

test("rejects lists longer than the limit", () => {
  const errors = Array.from({ length: 51 }, () => sample().errors[0]);
  assert.equal(parseReport(text({ ...sample(), errors })).ok, false);
});

test("rejects a page error whose line is not a whole number", () => {
  const errors = [{ ...sample().errors[0], line: 1.5 }];
  assert.equal(parseReport(text({ ...sample(), errors })).ok, false);
});
