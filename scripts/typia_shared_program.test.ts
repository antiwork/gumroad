import UnpluginTypia from "@typia/unplugin/vite";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { build, createServer, type InlineConfig, type Rollup } from "vite";
import { describe, expect, it, vi } from "vitest";

// Covers patches/@typia+unplugin+12.1.1.patch: a one-shot build shares one program
// (so a global type resolves), and dev keeps a program per file.
const fixture = path.join(path.dirname(fileURLToPath(import.meta.url)), "__fixtures__/typia_shared_program");
const config = (root = fixture, sharedProgram?: boolean): InlineConfig => ({
  root,
  configFile: false,
  logLevel: "silent",
  plugins: [UnpluginTypia({ cache: false, log: false, tsconfig: path.join(root, "tsconfig.json"), sharedProgram })],
});

// The source and line of each generated line's first mapping segment, from a v3 source map.
const firstMappings = (mappings: string) => {
  const digits = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  let source = 0;
  let sourceLine = 0;
  return mappings.split(";").map((line) => {
    let first: { source: number; line: number } | null = null;
    for (const segment of line.split(",").filter(Boolean)) {
      const fields: number[] = [];
      let value = 0;
      let shift = 0;
      for (const char of segment) {
        const digit = digits.indexOf(char);
        value += (digit & 31) << shift;
        if (digit & 32) shift += 5;
        else {
          fields.push(value & 1 ? -(value >> 1) : value >> 1);
          value = 0;
          shift = 0;
        }
      }
      if (fields.length < 4) continue;
      source += fields[1] ?? 0;
      sourceLine += fields[2] ?? 0;
      first ??= { source, line: sourceLine };
    }
    return first;
  });
};

// Returns each entry's code, keyed by entry name.
const buildOutput = async (entries: string[], root = fixture, sharedProgram?: boolean, sourcemap = false) => {
  const result = await build({
    ...config(root, sharedProgram),
    build: {
      write: false,
      minify: false,
      sourcemap,
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
      .flatMap((chunk) =>
        chunk.type === "chunk"
          ? [[chunk.name, sourcemap ? { code: chunk.code, map: chunk.map?.toString() } : chunk.code]]
          : [],
      ),
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

  it("produces the same output when the machine is slow", async () => {
    const expected = await buildOutput(["guardian"], fixture, undefined, true);
    expect(expected.guardian.code).not.toContain('expected: "Guardian "');
    expect(expected.guardian.map).toBeTruthy();
    // Every clock read jumps 10 s, as if each step of a transform were slow.
    let now = Date.prototype.getTime.call(new Date());
    const clock = vi.spyOn(Date.prototype, "getTime").mockImplementation(() => (now += 10_000));
    try {
      expect(await buildOutput(["guardian"], fixture, undefined, true)).toEqual(expected);
    } finally {
      clock.mockRestore();
    }
  }, 60_000);

  it("maps a re-indented line to its own source line", async () => {
    const result = await build({
      ...config(),
      build: {
        write: false,
        minify: false,
        sourcemap: true,
        lib: { entry: { guardian: path.join(fixture, "guardian.ts") }, formats: ["es"] },
      },
    });
    const outputs: Rollup.RollupOutput[] = Array.isArray(result) ? result : "output" in result ? [result] : [];
    const chunk = outputs
      .flatMap(({ output }) => output)
      .find((item) => item.type === "chunk" && item.name === "guardian");
    if (chunk?.type !== "chunk" || !chunk.map) throw new Error("no guardian chunk with a source map");
    const needle = '"saved, but incomplete"';
    const generatedLine = chunk.code.split("\n").findIndex((text) => text.includes(needle));
    const mapped = firstMappings(chunk.map.mappings)[generatedLine];
    expect(mapped && chunk.map.sources[mapped.source]).toMatch(/guardian\.ts$/u);
    const sourceLines = fs.readFileSync(path.join(fixture, "guardian.ts"), "utf8").split("\n");
    expect(mapped?.line).toBe(sourceLines.findIndex((text) => text.includes(needle)));
  }, 60_000);

  it("orders union members the same whichever file is transformed first", async () => {
    const unionFirst = await buildOutput(["union", "zeta"]);
    const zetaFirst = await buildOutput(["zeta", "union"]);
    // Rollup prints this string in single quotes, Rolldown in escaped double quotes.
    expect(unionFirst.union.replaceAll('\\"', '"')).toContain('("alpha" | "zeta")');
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

describe("rebuilding typia's output as an edit of the source", () => {
  const rebuildCases: [string, string, string][] = [
    ["two inserts at one offset", "b\n", "x\n  b\n"],
    ["CRLF source, LF output", "a\r\nb\r\n", "  a\n  b\n"],
    ["no final newline", "a\nb", "a\nb\nc"],
    ["empty source", "", "x\n"],
    ["empty output", "x\n", ""],
    ["inserts between re-indented lines", "  a\n  b\n  c\n", "x\n    a\ny\n    b\n    c\nz"],
    ["more distinct lines than line ids", Array.from({ length: 70_000 }, (_, i) => `line${i}\n`).join(""), "new\n"],
    ["a replaced line above the diff limit", `${"x".repeat(30_000)}\n`, `${"y".repeat(30_000)}\n`],
    [
      "more lines than the alignment limit",
      Array.from({ length: 12_000 }, (_, i) => `a${i}\n`).join(""),
      Array.from({ length: 12_000 }, (_, i) => `b${i}\n`).join(""),
    ],
    [
      "two-letter text above the piece limit",
      Array.from({ length: 15_000 }, (_, i) => ((i * 7919) % 3 ? "a" : "b")).join(""),
      Array.from({ length: 15_000 }, (_, i) => ((i * 104_729) % 5 ? "b" : "a")).join(""),
    ],
  ];

  it.each(rebuildCases)("rebuilds the output exactly: %s", async (_name, source, code) => {
    const { gumroadRebuild } = await import("../node_modules/@typia/unplugin/dist/core.js");
    const expected = code === "new\n" ? `new\n${source}` : code;
    expect(gumroadRebuild(source, expected).toString()).toBe(expected);
  });
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
    expect(code).toMatch(/__is = \(input\d*\) => true/u);
    expect(code).not.toContain('".count"');
  }, 60_000);

  it("keeps a program per file while a build runs in the same process", async () => {
    const code = await devTransform(() => buildOutput(["index"]));
    expect(code).toMatch(/__is = \(input\d*\) => true/u);
  }, 60_000);
});

describe("typia transform in vitest", () => {
  // The hook's vitest context, reduced to what it reads.
  type VitestHook = (context: { vitest: { config: { watch: boolean } } }) => void;
  const isVitestHook = (hook: unknown): hook is VitestHook => typeof hook === "function";
  const vitestTransform = async (watch: boolean) => {
    const server = await createServer({ ...config(), server: { middlewareMode: true }, appType: "custom" });
    try {
      const plugin = server.config.plugins.find((item) => item.name === "unplugin-typia");
      const hook: unknown = plugin && "configureVitest" in plugin ? plugin.configureVitest : undefined;
      if (!isVitestHook(hook)) throw new Error("unplugin-typia has no configureVitest hook");
      hook({ vitest: { config: { watch } } });
      return (await server.transformRequest("/index.ts"))?.code ?? "";
    } finally {
      await server.close();
    }
  };

  it("shares one program in a one-shot run", async () => {
    expect(await vitestTransform(false)).toContain('".count"');
  }, 60_000);

  it("keeps a program per file in watch mode", async () => {
    const code = await vitestTransform(true);
    expect(code).toMatch(/__is = \(input\d*\) => true/u);
    expect(code).not.toContain('".count"');
  }, 60_000);

  // spawnSync blocks the event loop, so the test's own timeout cannot fire while it runs;
  // the child's lower limit ends a stalled run first.
  const NESTED_RUN_TEST_TIMEOUT_MS = 60_000;
  const NESTED_RUN_KILL_AFTER_MS = 50_000;

  it(
    "checks a global .d.ts type in a real vitest run",
    () => {
      const vitest = path.join(fixture, "../../../node_modules/vitest/vitest.mjs");
      // Without this run's own VITEST* variables, so the nested vitest starts as a fresh one.
      const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith("VITEST")));
      const result = spawnSync(process.execPath, [vitest, "run", "--config", path.join(fixture, "vitest.config.mjs")], {
        cwd: fixture,
        env,
        encoding: "utf8",
        timeout: NESTED_RUN_KILL_AFTER_MS,
      });
      expect(result.status, `${result.stdout}${result.stderr}`).toBe(0);
    },
    NESTED_RUN_TEST_TIMEOUT_MS,
  );
});
