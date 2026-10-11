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
    },
  },
  test: {
    include: ["app/javascript/**/*.test.{ts,tsx}", "scripts/**/*.test.ts"],
    environment: "node",
  },
});
