import path from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

const rootPath = path.dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  resolve: {
    // Mirror the vite.config.ts aliases components under test import from.
    alias: {
      $app: path.resolve(rootPath, "app/javascript"),
      $assets: path.resolve(rootPath, "public"),
      $vendor: path.resolve(rootPath, "vendor/assets/javascripts"),
      // The barrel re-exports ~2,200 icon modules. Its ESM build is not valid for Node (no
      // "type": "module"), so vitest would transform every one of them in every test file.
      // Node loads the CommonJS build itself, once the entry below marks it external.
      "@boxicons/react": path.resolve(rootPath, "node_modules/@boxicons/react/dist/cjs/index.js"),
    },
  },
  test: {
    include: ["app/javascript/**/*.test.{ts,tsx}", "scripts/**/*.test.ts"],
    environment: "node",
    server: { deps: { external: [/\/node_modules\/@boxicons\/react\//u] } },
  },
});
