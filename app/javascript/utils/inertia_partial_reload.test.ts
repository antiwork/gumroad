// @vitest-environment happy-dom
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { describe, expect, it } from "vitest";

import { isUnredirectedPartialReloadResponse } from "$app/utils/inertia_partial_reload";

const CONTENT_PAGE_URL = "https://gumroad.com/d/abc123";

const POLL_HEADERS: unknown = {
  "X-Inertia": "true",
  "X-Inertia-Partial-Data": "latest_media_locations",
};

const pollResponse = ({
  headers = POLL_HEADERS,
  url = CONTENT_PAGE_URL,
  responseURL = CONTENT_PAGE_URL,
}: { headers?: unknown; url?: string; responseURL?: string } = {}) => ({
  config: { headers, url },
  request: { responseURL },
});

describe("isUnredirectedPartialReloadResponse", () => {
  it("matches a background partial reload answered from the URL it requested", () => {
    expect(isUnredirectedPartialReloadResponse(pollResponse())).toBe(true);
  });

  it("matches when axios has normalized the headers into an AxiosHeaders-like object", () => {
    const headers = { has: (name: string) => name.toLowerCase() === "x-inertia-partial-data" };

    expect(isUnredirectedPartialReloadResponse(pollResponse({ headers }))).toBe(true);
  });

  // The reason the guard checks for a redirect at all: an expired session or revoked access
  // sends the poll somewhere else, and the buyer does need to be moved off the page.
  it("does not match a partial reload that was redirected elsewhere", () => {
    expect(
      isUnredirectedPartialReloadResponse(pollResponse({ responseURL: "https://gumroad.com/login?next=/d/abc123" })),
    ).toBe(false);
  });

  // Inertia issues the poll against a relative path while the browser reports an absolute
  // `responseURL`, so the two have to be compared after resolving against the page's origin.
  it("treats a relative request URL resolving to the same page as unredirected", () => {
    const sameOrigin = `${window.location.origin}/d/abc123`;

    expect(isUnredirectedPartialReloadResponse(pollResponse({ url: "/d/abc123", responseURL: sameOrigin }))).toBe(true);
  });

  it("does not match a full page visit", () => {
    expect(isUnredirectedPartialReloadResponse(pollResponse({ headers: { "X-Inertia": "true" } }))).toBe(false);
  });

  it("does not match a response with no usable request metadata", () => {
    expect(isUnredirectedPartialReloadResponse(undefined)).toBe(false);
    expect(isUnredirectedPartialReloadResponse({})).toBe(false);
    expect(isUnredirectedPartialReloadResponse({ config: {} })).toBe(false);
  });

  // The gate only works because Inertia itself sets this header on partial reloads. If an
  // Inertia upgrade renames it, the gate would silently stop matching and background polls
  // could reload the page again — so pin the name against the installed library.
  it("keys off a header the installed Inertia version actually sends", () => {
    const require = createRequire(import.meta.url);
    const inertiaCore = readFileSync(require.resolve("@inertiajs/core"), "utf8");

    expect(inertiaCore).toContain("X-Inertia-Partial-Data");
  });
});
