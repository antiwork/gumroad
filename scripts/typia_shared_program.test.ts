import UnpluginTypia from "@typia/unplugin/vite";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { build, createServer, type InlineConfig, type Rollup } from "vite";
import { describe, expect, it } from "vitest";

// Covers patches/@typia+unplugin+12.1.1.patch: a one-shot build shares one program
// (so a global type resolves), and dev keeps a program per file.
const fixture = path.join(path.dirname(fileURLToPath(import.meta.url)), "__fixtures__/typia_shared_program");
const config = (root = fixture, sharedProgram?: boolean): InlineConfig => ({
  root,
  configFile: false,
  logLevel: "silent",
  plugins: [UnpluginTypia({ cache: false, log: false, tsconfig: path.join(root, "tsconfig.json"), sharedProgram })],
});

// Returns each entry's code, keyed by entry name.
const buildOutput = async (entries: string[], root = fixture, sharedProgram?: boolean) => {
  const result = await build({
    ...config(root, sharedProgram),
    build: {
      write: false,
      minify: false,
      lib: {
        entry: Object.fromEntries(entries.map((name) => [name, path.join(root, `${name}.ts`)])),
        formats: ["es"],
      },
    },
  });
  const outputs: Rollup.RollupOutput[] = Array.isArray(result) ? result : "output" in result ? [result] : [];
  return Object.fromEntries(
    outputs
      .flatMap(({ output }) => output)
      .flatMap((chunk) => (chunk.type === "chunk" ? [[chunk.name, chunk.code]] : [])),
  );
};

describe("typia transform in a one-shot build", () => {
  it("checks a field of a type declared only in a global .d.ts", async () => {
    expect((await buildOutput(["index"])).index).toContain('".count"');
  }, 60_000);

  it("keeps a program per file when sharedProgram is false", async () => {
    const code = (await buildOutput(["index"], fixture, false)).index;
    // typia ran, but the unresolved type became `any`: the assert returns its input unchecked.
    expect(code).toContain("errorFactory");
    expect(code).not.toContain('".count"');
  }, 60_000);

  it("orders union members the same whichever file is transformed first", async () => {
    const unionFirst = await buildOutput(["union", "zeta"]);
    const zetaFirst = await buildOutput(["zeta", "union"]);
    expect(unionFirst.union).toContain(`expected: '("alpha" | "zeta")'`);
    expect(zetaFirst.union).toBe(unionFirst.union);
  }, 60_000);

  it("reads a changed declaration in the next build of the same process", async () => {
    // Inside the repo, so the copy still resolves typia from node_modules.
    const root = fs.mkdtempSync(`${fixture}-`);
    try {
      fs.cpSync(fixture, root, { recursive: true });
      expect((await buildOutput(["index"], root)).index).toContain('expected: "number"');
      const globals = path.join(root, "globals.d.ts");
      fs.writeFileSync(globals, fs.readFileSync(globals, "utf8").replace("count: number", "count: string"));
      expect((await buildOutput(["index"], root)).index).toContain('expected: "string"');
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  }, 60_000);
});

describe("typia transform in dev", () => {
  const devTransform = async (beforeTransform?: () => Promise<unknown>) => {
    const server = await createServer({ ...config(), server: { middlewareMode: true }, appType: "custom" });
    try {
      await beforeTransform?.();
      return (await server.transformRequest("/index.ts"))?.code ?? "";
    } finally {
      await server.close();
    }
  };

  it("keeps a program per file, which does not see the global .d.ts", async () => {
    const code = await devTransform();
    // The unresolved type becomes `any`: a validator that accepts anything.
    expect(code).toContain("__is = (input2) => true");
    expect(code).not.toContain('".count"');
  }, 60_000);

  it("keeps a program per file while a build runs in the same process", async () => {
    const code = await devTransform(() => buildOutput(["index"]));
    expect(code).toContain("__is = (input2) => true");
  }, 60_000);
});
