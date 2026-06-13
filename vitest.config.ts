import path from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

const rootPath = path.dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  resolve: {
    alias: { $app: path.resolve(rootPath, "app/javascript") },
  },
  test: {
    include: ["app/javascript/**/*.test.{ts,tsx}"],
    environment: "node",
  },
});
