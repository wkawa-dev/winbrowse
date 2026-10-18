import { defineConfig } from "cf/config";

export default defineConfig({
  worker: {
    "name": "winbrowse",
    "compatibilityDate": "2026-09-25",
    "observability": {
      "enabled": true
    }
  }
});
