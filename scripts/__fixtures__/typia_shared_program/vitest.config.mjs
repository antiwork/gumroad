import UnpluginTypia from "@typia/unplugin/vite";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

const root = path.dirname(fileURLToPath(import.meta.url));

// Run by scripts/typia_shared_program.test.ts as a real `vitest run` of this fixture.
export default defineConfig({
  root,
  // Outside the repository, so the run leaves no files in the fixture.
  cacheDir: path.join(os.tmpdir(), "typia-shared-program-vitest"),
  plugins: [UnpluginTypia({ cache: false, log: false, tsconfig: path.join(root, "tsconfig.json") })],
  test: { include: ["global_shape.vitest.mjs"], environment: "node" },
});
