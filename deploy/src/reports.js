export const MAX_BYTES = 256 * 1024;

const MAX_ITEMS = 50;

class Invalid extends Error {}

export function parseReport(text) {
  let value;
  try {
    value = JSON.parse(text);
  } catch {
    return { ok: false, error: "the report is not valid JSON" };
  }
  try {
    return { ok: true, ...intake(value) };
  } catch (error) {
    if (error instanceof Invalid) return { ok: false, error: error.message };
    throw error;
  }
}

function intake(value) {
  const r = object(value, "report");
  const url = text(r.url, "url", 2048);
  const appVersion = text(r.appVersion, "appVersion", 64);
  const system = text(r.system, "system", 128);
  return {
    site: siteOf(url),
    appVersion,
    system,
    report: {
      url,
      appVersion,
      system,
      userAgent: text(r.userAgent, "userAgent", 512),
      desktopSite: flag(r.desktopSite, "desktopSite"),
      protections: list(r.protections, "protections", (item) => text(item, "protection", 32)),
      rulesets: list(r.rulesets, "rulesets", (item) => text(item, "ruleset", 64)),
      filterListVersion: text(r.filterListVersion, "filterListVersion", 64),
      extensions: list(r.extensions, "extensions", extension),
      compile: r.compile == null ? null : object(r.compile, "compile"),
      errors: list(r.errors, "errors", pageError),
      created: text(r.created, "created", 64),
    },
  };
}

function siteOf(url) {
  let parsed;
  try {
    parsed = new URL(url);
  } catch {
    throw new Invalid("url is not a web address");
  }
  if (parsed.protocol !== "https:" && parsed.protocol !== "http:") throw new Invalid("url must be http or https");
  return parsed.hostname;
}

function extension(value) {
  const e = object(value, "extension");
  return {
    id: text(e.id, "extension id", 64),
    version: text(e.version, "extension version", 32),
    enabled: flag(e.enabled, "extension enabled"),
  };
}

function pageError(value) {
  const e = object(value, "page error");
  return {
    kind: text(e.kind, "error kind", 32),
    message: text(e.message, "error message", 500),
    page: text(e.page, "error page", 2048),
    source: text(e.source, "error source", 2048),
    line: integer(e.line, "error line"),
    date: text(e.date, "error date", 64),
  };
}

function object(value, name) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Invalid(`${name} must be an object`);
  return value;
}

function text(value, name, max) {
  if (typeof value !== "string" || value.length > max) throw new Invalid(`${name} must be text of at most ${max} characters`);
  return value;
}

function flag(value, name) {
  if (typeof value !== "boolean") throw new Invalid(`${name} must be true or false`);
  return value;
}

function integer(value, name) {
  if (!Number.isSafeInteger(value)) throw new Invalid(`${name} must be a whole number`);
  return value;
}

function list(value, name, item) {
  if (!Array.isArray(value) || value.length > MAX_ITEMS) throw new Invalid(`${name} must be a list of at most ${MAX_ITEMS} items`);
  return value.map(item);
}
