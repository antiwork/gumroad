import UnpluginTypia from "@typia/unplugin/vite";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

const rootPath = path.dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  // The same typia transform the app build uses (vite.config.ts), so code under test that calls
  // typia.assert<T>() runs its real generated validator instead of throwing at runtime.
  // `vitest run` shares one TypeScript program across files, as the build does; watch mode
  // keeps a program per file, where types declared only in a global .d.ts become `any`.
  plugins: [UnpluginTypia({ cache: true })],
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
