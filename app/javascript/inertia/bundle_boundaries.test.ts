import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import ts from "typescript";
import { describe, expect, it } from "vitest";

import { codeSplittingGroups, manualChunks, SHELL_ENTRY } from "../../../config/vite/manual-chunks";

// A shell that statically imports React and lazy-loads a page that imports libphonenumber-js.
const PAGE = "/repo/app/javascript/pages/Checkout/Show.tsx";
const REACT = "/repo/node_modules/react/index.js";
const PHONE = "/repo/node_modules/libphonenumber-js/index.js";
const graph: Record<string, string[]> = { [SHELL_ENTRY]: [REACT], [REACT]: [], [PAGE]: [REACT, PHONE], [PHONE]: [] };
const context = {
  getModuleInfo: (id: string) => (id in graph ? { importedIds: graph[id] ?? [] } : null),
};

const SOURCE_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const REPO_ROOT = resolve(SOURCE_ROOT, "../..");
const MODULE_FILE = /\.(?:[cm]?js|jsx|tsx?)$/u;
const { options: COMPILER_OPTIONS } = ts.parseJsonConfigFileContent(
  ts.readConfigFile(join(REPO_ROOT, "tsconfig.json"), (path) => ts.sys.readFile(path)).config,
  ts.sys,
  REPO_ROOT,
);
const STATIC_IMPORT = /^(?:import|export)\s(?:[^"';]*?\sfrom\s)?["'](?<specifier>[^"']+)["']/gmu;

// Transpiling drops imports whose names are only used as types, as the bundler does, so the walk
// follows exactly the imports that ship. Cached because the pages share most of their modules.
const importsByFile = new Map<string, string[]>();
const staticImports = (file: string) => {
  let imports = importsByFile.get(file);
  if (!imports) {
    const { outputText } = ts.transpileModule(readFileSync(file, "utf8"), {
      fileName: file,
      compilerOptions: {
        module: ts.ModuleKind.ESNext,
        target: ts.ScriptTarget.ESNext,
        jsx: ts.JsxEmit.Preserve,
        verbatimModuleSyntax: false,
      },
    });
    imports = [...outputText.matchAll(STATIC_IMPORT)].map(({ groups }) => groups?.specifier ?? "");
    importsByFile.set(file, imports);
  }
  return imports;
};

// Every source file and npm package a page reaches through static imports: what loads before it mounts.
const staticClosure = (page: string) => {
  const files = new Set<string>();
  const packages = new Set<string>();
  const pending = [join(SOURCE_ROOT, page)];
  for (let file = pending.pop(); file !== undefined; file = pending.pop()) {
    if (files.has(file)) continue;
    files.add(file);
    for (const specifier of staticImports(file)) {
      const resolved = ts.resolveModuleName(specifier, file, COMPILER_OPTIONS, ts.sys).resolvedModule;
      // Unresolved local specifiers are assets (styles, `?url` images), which hold no imports.
      if (resolved?.isExternalLibraryImport || (!resolved && !/^[.$]/u.test(specifier))) packages.add(specifier);
      else if (resolved && MODULE_FILE.test(resolved.resolvedFileName)) pending.push(resolved.resolvedFileName);
    }
  }
  return { files: [...files].map((file) => file.slice(SOURCE_ROOT.length + 1)), packages: [...packages] };
};

const STOREFRONT_PAGES = [
  "pages/Products/Show.tsx",
  "pages/Products/Profile/Show.tsx",
  "pages/Products/Discover/Show.tsx",
  "pages/Users/Show.tsx",
];

// No visible failure if these regress — the app still works, just ships extra bytes.
describe("Inertia page bundle boundaries", () => {
  it("keeps colocated page tests out of the page glob", async () => {
    const source = (await import("$app/entrypoints/inertia.js?raw")).default.replace(/\/\/[^\n]*/gu, "");
    const globs = [...source.matchAll(/import\.meta\.glob\(\[([^\]]+)\]\)/gu)].map(([, args = ""]) => args);
    expect(globs).not.toHaveLength(0);
    for (const args of globs) expect(args).toMatch(/!\.\.\/pages\/\*\*\/\*\.test\./u);

    const included = Object.keys(import.meta.glob(["../pages/**/*.tsx", "!../pages/**/*.test.tsx"])).map(String);
    const unfiltered = Object.keys(import.meta.glob("../pages/**/*.tsx")).map(String);
    expect(unfiltered.some((key) => key.endsWith(".test.tsx"))).toBe(true);
    expect(included.some((key) => key.includes(".test."))).toBe(false);
  });

  it("pins Vite's dynamic-import helper to the vendor chunk", async () => {
    const configSource = (await import("../../../vite.config.ts?raw")).default.replace(/\/\/[^\n]*/gu, "");
    expect(configSource).toMatch(/from\s+["']\.\/config\/vite\/manual-chunks\.ts["']/u);
    expect(configSource).toMatch(/groups:\s*codeSplittingGroups/u);
    expect(codeSplittingGroups).toContainEqual({ name: manualChunks });

    expect(manualChunks("vite/preload-helper", context)).toBe("vendor");
    expect(manualChunks("\0vite/preload-helper.js", context)).toBe("vendor");
    expect(manualChunks("/node_modules/pdfjs-dist/build/pdf.js", context)).toBe("vendor-pdf");
  });

  it("keeps packages that only lazy-loaded pages import out of the vendor chunk", () => {
    expect(manualChunks(REACT, context)).toBe("vendor");
    expect(manualChunks(PHONE, context)).toBeUndefined();
    expect(manualChunks(PAGE, context)).toBeUndefined();
  });

  it.each(STOREFRONT_PAGES)("keeps the rich text editor off the blocking path of %s", (page) => {
    const { files, packages } = staticClosure(page);
    // Guards against the walker silently resolving nothing.
    expect(files).toEqual(expect.arrayContaining(["components/Profile/Sections.tsx", "components/Product/index.tsx"]));

    expect(
      packages.filter((name) => /^(?:@tiptap\/|prosemirror-|lowlight|highlight\.js|react-sortablejs)/u.test(name)),
    ).toEqual([]);
    expect(
      files.filter((file) =>
        /^components\/(?:RichTextEditor|ProductEdit\/ProductTab\/DescriptionEditor|Profile\/EditSections|Product\/Description|Product\/SectionEditor|Profile\/RichTextSection)\.tsx$/u.test(
          file,
        ),
      ),
    ).toEqual([]);
  });

  // Checkout imports ConfigurationSelector for its pricing helpers.
  it.each([...STOREFRONT_PAGES, "pages/Checkout/Show.tsx"])(
    "keeps the call calendar off the blocking path of %s",
    (page) => {
      const { files, packages } = staticClosure(page);
      expect(files).toContain("components/Product/ConfigurationSelector.tsx");

      expect(packages).not.toContain("react-day-picker");
      expect(files).not.toContain("components/ui/Calendar.tsx");
    },
  );
});
