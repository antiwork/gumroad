import { fileURLToPath } from "node:url";
import path from "path";

import UnpluginTypia from "@typia/unplugin/vite";
import react from "@vitejs/plugin-react";
import AutoImport from "unplugin-auto-import/vite";
import { defineConfig } from "vite";
import RubyPlugin from "vite-plugin-ruby";

const rootPath = path.dirname(fileURLToPath(import.meta.url));

function stripCjsExportsPlugin() {
  return {
    name: "strip-cjs-exports",
    transform(code: string, id: string) {
      if (id.endsWith("routes.js")) {
        return code.replace(/^Object\.defineProperty\(exports.*$/m, "").replace(/^exports\.\w+\s*=.*$/gm, "");
      }
    },
  };
}

// Vite's default progress spinner overwrites a single "transforming..." line, which
// stays static in CI (non-TTY) — you see the start, then nothing until done. This
// plugin replaces it with timestamped heartbeats and a final duration line. We emit
// on whichever comes first: every TRANSFORM_TICK modules or every TIME_TICK_MS. The
// time-based fallback matters because the first hundreds of modules can take >1min
// when typia AOT / dependency resolution dominate, leaving CI looking hung.
// Build-only, CI-only.
function ciProgressPlugin() {
  if (!process.env.CI) return null;
  const TRANSFORM_TICK = 100;
  const TIME_TICK_MS = 15_000;
  let start = 0;
  let count = 0;
  let lastTick = 0;
  return {
    name: "ci-progress",
    apply: "build" as const,
    buildStart() {
      start = Date.now();
      lastTick = start;
      console.log(`[vite] build start ${new Date().toISOString()}`);
    },
    transform() {
      count++;
      const now = Date.now();
      if (count % TRANSFORM_TICK === 0 || now - lastTick >= TIME_TICK_MS) {
        const elapsed = ((now - start) / 1000).toFixed(1);
        console.log(`[vite] transformed ${count} modules in ${elapsed}s`);
        lastTick = now;
      }
    },
    buildEnd(err?: Error) {
      const elapsed = ((Date.now() - start) / 1000).toFixed(1);
      console.log(`[vite] build ${err ? "failed" : "done"} after ${elapsed}s, ${count} modules transformed`);
    },
  };
}

export default defineConfig({
  plugins: [
    RubyPlugin(),
    react(),
    UnpluginTypia({ cache: true }),
    AutoImport({
      imports: [{ "$app/utils/routes": [["*", "Routes"]] }],
    }),
    stripCjsExportsPlugin(),
    ciProgressPlugin(),
  ],
  resolve: {
    alias: {
      $app: path.join(rootPath, "app/javascript"),
      $assets: path.join(rootPath, "app/assets"),
      $vendor: path.join(rootPath, "vendor/assets/javascripts"),
      jwplayer: path.join(rootPath, "vendor/assets/components/jwplayer-7.12.13/jwplayer"),
      "~fonts": path.join(rootPath, "app/assets/fonts"),
      "~images": path.join(rootPath, "app/assets/images"),
    },
  },
  define: {
    SSR: false,
    "process.env.NODE_ENV": JSON.stringify(process.env.NODE_ENV || "test"),
    "process.env.RAILS_ENV": JSON.stringify(process.env.RAILS_ENV || "test"),
    "process.env.PROTOCOL": JSON.stringify(process.env.PROTOCOL || "https"),
    "process.env": "{}",
  },
  css: {
    preprocessorOptions: {
      scss: {
        loadPaths: [path.join(rootPath, "app/assets")],
      },
    },
  },
});
