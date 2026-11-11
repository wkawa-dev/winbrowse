import { bindings, defineConfig, defineWorker } from "@cloudflare/config";
import * as entrypoint from "./src/index.js" with { type: "cf-worker" };

export default defineConfig({
  worker: defineWorker({
    name: "winbrowse",
    compatibilityDate: "2026-09-25",
    observability: {
      enabled: true
    },
    entrypoint,
    assets: {
      runWorkerFirst: ["/api/*"]
    },
    env: {
      ASSETS: bindings.assets(),
      REPORTS: bindings.d1({ name: "winbrowse-reports" }),
      REPORT_LIMIT: bindings.rateLimit({ namespace: "1001", simple: { limit: 10, period: 60 } })
    }
  })
});
