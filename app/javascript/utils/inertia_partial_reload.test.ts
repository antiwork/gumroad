// @vitest-environment happy-dom
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { describe, expect, it } from "vitest";

import { isPartialReloadResponse } from "$app/utils/inertia_partial_reload";

const responseWithHeaders = (headers: unknown) => ({ config: { headers } });

describe("isPartialReloadResponse", () => {
  it("recognizes a background partial reload from the header Inertia sets on it", () => {
    expect(
      isPartialReloadResponse(
        responseWithHeaders({
          "X-Inertia": "true",
          "X-Inertia-Partial-Component": "UrlRedirects/DownloadPage",
          "X-Inertia-Partial-Data": "latest_media_locations",
        }),
      ),
    ).toBe(true);
  });

  it("recognizes it when axios has normalized the headers into an AxiosHeaders-like object", () => {
    const headers = { has: (name: string) => name.toLowerCase() === "x-inertia-partial-data" };

    expect(isPartialReloadResponse(responseWithHeaders(headers))).toBe(true);
  });

  it("does not treat a full page visit as a partial reload", () => {
    expect(isPartialReloadResponse(responseWithHeaders({ "X-Inertia": "true" }))).toBe(false);
  });

  it("does not treat a response with no request config as a partial reload", () => {
    expect(isPartialReloadResponse(undefined)).toBe(false);
    expect(isPartialReloadResponse({})).toBe(false);
    expect(isPartialReloadResponse({ config: {} })).toBe(false);
  });

  // The gate above only works because Inertia itself sets this header on partial reloads. If an
  // Inertia upgrade renames it, the gate would silently stop matching and background polls would
  // be able to reload the page again — so pin the name against the installed library.
  it("keys off a header the installed Inertia version actually sends", () => {
    const require = createRequire(import.meta.url);
    const inertiaCore = readFileSync(require.resolve("@inertiajs/core"), "utf8");

    expect(inertiaCore).toContain("X-Inertia-Partial-Data");
  });
});
