import { defineConfig } from "cf/config";

// wbwriter.app: static marketing site for WBWrite, served as an assets-only Worker.
export default defineConfig({
  accountId: "e36d835e50ed1d218b74e0360c270ec4",
  worker: {
    name: "wbwriter-site",
    compatibilityDate: "2026-10-06",
    domains: ["wbwriter.app", "www.wbwriter.app"],
    assets: {
      htmlHandling: "auto-trailing-slash",
      notFoundHandling: "none",
    },
    observability: {
      enabled: true,
    },
  },
});
