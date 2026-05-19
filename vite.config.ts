import { fileURLToPath } from "node:url";
import path from "path";

import UnpluginTypia from "@typia/unplugin/vite";
import react from "@vitejs/plugin-react";
import AutoImport from "unplugin-auto-import/vite";
import { defineConfig } from "vite";
import RubyPlugin from "vite-plugin-ruby";
import { visualizer } from "rollup-plugin-visualizer";

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

// Vendor chunk splitting — keeps large, leaf-node dependencies in stable,
// independently cacheable chunks so that app-code deploys don't bust CDN
// caches for vendor code that rarely changes.
//
// Strategy: pull out large libraries that DON'T import React (pure JS libs)
// into their own chunks. Everything React-dependent stays in one "vendor"
// chunk to avoid circular cross-chunk imports between React internals and
// the many small packages that re-export them.
function manualChunks(id: string) {
  if (!id.includes("node_modules")) return;

  // Rich-text editor (Tiptap + ProseMirror) — self-contained, ~97KB gzip
  if (id.includes("/@tiptap/") || id.includes("/prosemirror-")) {
    return "vendor-editor";
  }

  // Charts (Recharts + D3) — self-contained, ~82KB gzip
  if (id.includes("/recharts/") || id.includes("/d3-") || id.includes("/recharts-scale/") || id.includes("/victory-")) {
    return "vendor-charts";
  }

  // Braintree / PayPal — self-contained, ~41KB gzip
  if (id.includes("/braintree-web/") || id.includes("/@paypal/")) {
    return "vendor-payments";
  }

  // PDF.js worker — huge (2.3MB), loaded lazily on demand
  if (id.includes("/pdfjs-dist/")) {
    return "vendor-pdf";
  }

  // Everything else from node_modules → single vendor chunk.
  // This includes React, Inertia, Radix, Stripe, date-fns, lodash, etc.
  // Keeping them together avoids circular chunk warnings from the deep
  // cross-imports between React and its ecosystem packages.
  return "vendor";
}

export default defineConfig(({ mode }) => ({
  plugins: [
    RubyPlugin(),
    react(),
    UnpluginTypia({ cache: true }),
    AutoImport({
      imports: [{ "$app/utils/routes": [["*", "Routes"]] }],
    }),
    stripCjsExportsPlugin(),
    // Bundle visualizer — only emitted during production builds.
    // Run `npx vite build` then open tmp/bundle-stats.html to audit chunk sizes.
    ...(mode === "production"
      ? [
          visualizer({
            filename: "tmp/bundle-stats.html",
            gzipSize: true,
            brotliSize: true,
          }),
        ]
      : []),
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
  build: {
    // Stable content-hash filenames for long-lived CDN caching.
    // Rollup's default [hash] is already content-based, but we make the
    // pattern explicit so it survives Vite major bumps.
    rollupOptions: {
      output: {
        manualChunks,
        // [name]-[hash] keeps filenames readable in devtools / logs
        chunkFileNames: "assets/[name]-[hash].js",
        entryFileNames: "assets/[name]-[hash].js",
        assetFileNames: "assets/[name]-[hash][extname]",
      },
    },
    // Raise chunk size warning limit — the combined vendor chunk is large
    // but it's a single cacheable unit that changes infrequently.
    chunkSizeWarningLimit: 800,
  },
}));
