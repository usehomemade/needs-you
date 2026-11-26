import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "astro/config";

// Static output (dist/): serve it from any static host (Coolify with the
// Dockerfile here, or Cloudflare Pages with "dist" as the output folder).
export default defineConfig({
  // Final domain not chosen yet: set SITE_URL at build time for absolute OG URLs.
  site: process.env.SITE_URL || undefined,
  output: "static",
  build: { inlineStylesheets: "auto" },
  // Scripts inline into the page (no module fetch), so the page also runs
  // inside a sandboxed iframe with an opaque origin (preview hosting).
  vite: { plugins: [tailwindcss()], build: { assetsInlineLimit: 100000 } },
});
