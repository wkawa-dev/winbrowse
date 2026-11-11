import { MAX_BYTES, parseReport } from "./reports.js";

export default {
  async fetch(request, env) {
    if (new URL(request.url).pathname !== "/api/reports") return env.ASSETS.fetch(request);
    if (request.method !== "POST") return reply(405, { error: "send a POST" }, { allow: "POST" });
    const { success } = await env.REPORT_LIMIT.limit({ key: request.headers.get("cf-connecting-ip") ?? "unknown" });
    if (!success) return reply(429, { error: "too many reports; wait a minute" }, { "retry-after": "60" });
    return submit(request, env);
  },
};

async function submit(request, env) {
  if (!(request.headers.get("content-type") ?? "").startsWith("application/json")) {
    return reply(415, { error: "send application/json" });
  }
  const text = await readBody(request);
  if (text === null) return reply(413, { error: `a report is at most ${MAX_BYTES} bytes` });
  const parsed = parseReport(text);
  if (!parsed.ok) return reply(400, { error: parsed.error });
  const id = crypto.randomUUID();
  await env.REPORTS.prepare(
    "INSERT INTO breakage_reports (id, received_at, site, app_version, system, report) VALUES (?, ?, ?, ?, ?, ?)",
  )
    .bind(id, new Date().toISOString(), parsed.site, parsed.appVersion, parsed.system, JSON.stringify(parsed.report))
    .run();
  return reply(201, { id });
}

async function readBody(request) {
  if (!request.body) return "";
  const declared = Number(request.headers.get("content-length") ?? 0);
  if (declared > MAX_BYTES) return null;
  const reader = request.body.getReader();
  const chunks = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > MAX_BYTES) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(bytes);
}

function reply(status, body, headers = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...headers },
  });
}
