import fs from "node:fs";
import type { Plugin } from "vite";

/**
 * Dev-only guard against the Vite dev server serving stale modules.
 *
 * Vite's dev server caches each module's transform result and relies on file
 * watcher events (chokidar/FSEvents) to invalidate that cache. On macOS the
 * watcher misses events in real situations — most commonly when git rewrites
 * many files at once (branch switch, rebase, stash pop) — and the server then
 * keeps serving old code until someone restarts it. That failure mode is
 * silent: the page loads fine, it's just not running the code on disk.
 *
 * This plugin removes the trust in watcher events: it records when each file
 * was last transformed, and a request middleware stats the file before Vite's
 * transform middleware serves it. If the file on disk is newer than the
 * cached transform, the module (and its importers) are invalidated so the
 * request re-transforms from disk. Cost is one fs.stat per module request in
 * dev; production builds are untouched (apply: "serve").
 */
export function staleModuleGuard(): Plugin {
  // file path -> epoch ms when we last transformed it
  const transformedAt = new Map<string, number>();

  return {
    name: "stale-module-guard",
    apply: "serve",
    transform(_code, id) {
      // id may carry a query (e.g. ?v=hash); key by the bare file path
      transformedAt.set(id.split("?")[0], Date.now());
      return null;
    },
    configureServer(server) {
      // In development this app serves its assets under a base path
      // ("/vite-dev/" — see config/vite.json), but Vite's module graph keys
      // URLs without that prefix. Plugin middlewares run before Vite strips
      // the base from req.url, so we have to strip it ourselves or every
      // module graph lookup below silently misses.
      const base = server.config.base;
      server.middlewares.use((req, _res, next) => {
        void (async () => {
          try {
            let url = req.url?.split("?")[0];
            if (url && base !== "/" && url.startsWith(base)) {
              url = url.slice(base.length - 1);
            }
            if (url && /\.(?:[jt]sx?|css|scss|json)$/u.test(url)) {
              const mod = await server.moduleGraph.getModuleByUrl(url);
              const file = mod?.file;
              if (mod && file && mod.transformResult) {
                const t = transformedAt.get(file);
                const { mtimeMs } = await fs.promises.stat(file);
                if (t !== undefined && mtimeMs > t) {
                  // File changed after we transformed it but no invalidation
                  // happened — the watcher missed it. Invalidate so this
                  // request gets fresh output.
                  server.moduleGraph.invalidateModule(mod);
                }
              }
            }
          } catch {
            // Never let the guard break serving (e.g. stat on a deleted file).
          }
          next();
        })();
      });
    },
  };
}
