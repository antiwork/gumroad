import { fileURLToPath } from "node:url";

type ModuleInfo = { importedIds: readonly string[] };
type ChunkingContext = { getModuleInfo(id: string): ModuleInfo | null };

// Every page's layout loads this entry; it imports `inertia.js`, which lazy-loads each page.
export const SHELL_ENTRY = fileURLToPath(new URL("../../app/javascript/entrypoints/base.ts", import.meta.url));

// Keyed by the entry's ModuleInfo, which rolldown reuses within one chunking pass, so a rebuild
// recomputes the set instead of reading a stale graph.
const shellModulesCache = new WeakMap<ModuleInfo, Set<string>>();

function shellModules(context: ChunkingContext) {
  const entry = context.getModuleInfo(SHELL_ENTRY);
  // An empty set would silently put every package back on the lazy path, so fail the build.
  if (!entry) throw new Error(`Shell entry ${SHELL_ENTRY} is not in the module graph`);
  let modules = shellModulesCache.get(entry);
  if (!modules) {
    modules = new Set<string>();
    const pending = [SHELL_ENTRY];
    for (let id = pending.pop(); id !== undefined; id = pending.pop()) {
      if (modules.has(id)) continue;
      modules.add(id);
      pending.push(...(context.getModuleInfo(id)?.importedIds ?? []));
    }
    shellModulesCache.set(entry, modules);
  }
  return modules;
}

export function manualChunks(id: string, context: ChunkingContext) {
  // Before the node_modules early-return: this helper is not always under node_modules, and
  // leaving it unpinned lets rollup park it in a lazy chunk every page then statically imports.
  if (id.includes("vite/preload-helper")) return "vendor";

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

  // EPUB reader — loaded only from the buyer's EPUB read page
  if (
    id.includes("/epubjs/") ||
    id.includes("/jszip/") ||
    id.includes("/localforage/") ||
    id.includes("/@xmldom/xmldom/") ||
    id.includes("/event-emitter/") ||
    id.includes("/marks-pane/") ||
    id.includes("/path-webpack/")
  ) {
    return "vendor-epub";
  }

  // PDF.js worker — huge (2.3MB), loaded lazily on demand
  if (id.includes("/pdfjs-dist/")) {
    return "vendor-pdf";
  }

  // `vendor` is on every page's blocking path, so it holds only what the shell imports statically.
  // The set is closed under static imports, so `vendor` never imports a page chunk back.
  if (shellModules(context).has(id)) return "vendor";
}

export const codeSplittingGroups = [
  // Recharts and epubjs both use CommonJS lodash. A group also captures its dependencies, so without
  // this higher-priority group lodash lands in vendor-charts and the EPUB reader downloads the charts.
  { name: "vendor-lodash", test: /node_modules[\\/]lodash[\\/]/u, priority: 1 },
  { name: manualChunks },
];
