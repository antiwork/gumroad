import UnpluginTypia from "@typia/unplugin/vite";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { build, createServer, type InlineConfig, type Rollup } from "vite";
import { describe, expect, it } from "vitest";

// Covers patches/@typia+unplugin+12.1.1.patch: a one-shot build shares one program
// (so a global type resolves), and dev keeps a program per file.
const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "__fixtures__/typia_shared_program");
const config = (): InlineConfig => ({
  root,
  configFile: false,
  logLevel: "silent",
  plugins: [UnpluginTypia({ cache: false, log: false, tsconfig: path.join(root, "tsconfig.json") })],
});

const buildOutput = async () => {
  const result = await build({
    ...config(),
    build: {
      write: false,
      minify: false,
      lib: { entry: path.join(root, "index.ts"), formats: ["es"], fileName: "index" },
    },
  });
  const outputs: Rollup.RollupOutput[] = Array.isArray(result) ? result : "output" in result ? [result] : [];
  return outputs
    .flatMap(({ output }) => output)
    .map((chunk) => (chunk.type === "chunk" ? chunk.code : ""))
    .join("\n");
};

describe("typia transform in a one-shot build", () => {
  it("checks a field of a type declared only in a global .d.ts", async () => {
    expect(await buildOutput()).toContain('".count"');
  }, 60_000);

  it("produces the same output twice", async () => {
    expect(await buildOutput()).toBe(await buildOutput());
  }, 60_000);
});

describe("typia transform in dev", () => {
  it("keeps a program per file, which does not see the global .d.ts", async () => {
    const server = await createServer({ ...config(), server: { middlewareMode: true }, appType: "custom" });
    try {
      const code = (await server.transformRequest("/index.ts"))?.code ?? "";
      // The unresolved type becomes `any`: a validator that accepts anything.
      expect(code).toContain("__is = (input2) => true");
      expect(code).not.toContain('".count"');
    } finally {
      await server.close();
    }
  }, 60_000);
});
