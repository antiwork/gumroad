// @vitest-environment happy-dom
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { describe, expect, it } from "vitest";

import { isUnredirectedDownloadPagePollResponse } from "$app/utils/inertia_partial_reload";

const CONTENT_PAGE_URL = "https://gumroad.com/d/abc123";

const POLL_HEADERS: unknown = {
  "X-Inertia": "true",
  "X-Inertia-Partial-Component": "UrlRedirects/DownloadPage",
  "X-Inertia-Partial-Data": "latest_media_locations",
};

const pollResponse = ({
  headers = POLL_HEADERS,
  method = "get",
  url = CONTENT_PAGE_URL,
  responseURL = CONTENT_PAGE_URL,
}: { headers?: unknown; method?: string; url?: string; responseURL?: string } = {}) => ({
  config: { headers, method, url },
  request: { responseURL },
});

// A stand-in for the AxiosHeaders instance axios normalizes request headers into: a
// case-insensitive `get` over whatever the caller set.
const axiosHeaders = (values: Record<string, string>) => ({
  get: (name: string) => values[Object.keys(values).find((key) => key.toLowerCase() === name.toLowerCase()) ?? ""],
});

describe("isUnredirectedDownloadPagePollResponse", () => {
  it("matches a content page poll answered from the URL it requested", () => {
    expect(isUnredirectedDownloadPagePollResponse(pollResponse())).toBe(true);
  });

  it("matches the audio-durations poll, and both polling props requested together", () => {
    const forProps = (props: string) =>
      pollResponse({
        headers: {
          "X-Inertia": "true",
          "X-Inertia-Partial-Component": "UrlRedirects/DownloadPage",
          "X-Inertia-Partial-Data": props,
        },
      });

    expect(isUnredirectedDownloadPagePollResponse(forProps("audio_durations"))).toBe(true);
    expect(isUnredirectedDownloadPagePollResponse(forProps("audio_durations,latest_media_locations"))).toBe(true);
  });

  it("matches when axios has normalized the headers into an AxiosHeaders-like object", () => {
    const headers = axiosHeaders({
      "X-Inertia": "true",
      "X-Inertia-Partial-Component": "UrlRedirects/DownloadPage",
      "X-Inertia-Partial-Data": "latest_media_locations",
    });

    expect(isUnredirectedDownloadPagePollResponse(pollResponse({ headers }))).toBe(true);
  });

  // Inertia sets `X-Inertia-Partial-Data` for EVERY `only:` visit, and the app makes dozens of
  // those from forms, searches, and explicit reloads. Keying on the header alone would silently
  // swallow real non-Inertia responses to all of them.
  it("does not match an `only:` visit from a different page", () => {
    const headers = {
      "X-Inertia": "true",
      "X-Inertia-Partial-Component": "Products/Edit",
      "X-Inertia-Partial-Data": "product",
    };

    expect(isUnredirectedDownloadPagePollResponse(pollResponse({ headers }))).toBe(false);
  });

  // The content page can make `only:` visits of its own for things that are not the polls; those
  // are user-initiated and must keep the navigating behavior.
  it("does not match a content page partial reload asking for a non-polling prop", () => {
    const headers = {
      "X-Inertia": "true",
      "X-Inertia-Partial-Component": "UrlRedirects/DownloadPage",
      "X-Inertia-Partial-Data": "audio_durations,content",
    };

    expect(isUnredirectedDownloadPagePollResponse(pollResponse({ headers }))).toBe(false);
  });

  // A poll is always a GET. Swallowing a non-Inertia answer to a write would hide a failed
  // submission from the buyer with no sign anything went wrong.
  it("does not match a non-GET request", () => {
    expect(isUnredirectedDownloadPagePollResponse(pollResponse({ method: "post" }))).toBe(false);
    // A config with no method at all is not provably a poll either.
    expect(
      isUnredirectedDownloadPagePollResponse({
        config: { headers: POLL_HEADERS, url: CONTENT_PAGE_URL },
        request: { responseURL: CONTENT_PAGE_URL },
      }),
    ).toBe(false);
  });

  // The reason the guard checks for a redirect at all: an expired session or revoked access
  // sends the poll somewhere else, and the buyer does need to be moved off the page.
  it("does not match a poll that was redirected elsewhere", () => {
    expect(
      isUnredirectedDownloadPagePollResponse(pollResponse({ responseURL: "https://gumroad.com/login?next=/d/abc123" })),
    ).toBe(false);
  });

  // Inertia issues the poll against a relative path while the browser reports an absolute
  // `responseURL`, so the two have to be compared after resolving against the page's origin.
  it("treats a relative request URL resolving to the same page as unredirected", () => {
    const sameOrigin = `${window.location.origin}/d/abc123`;

    expect(isUnredirectedDownloadPagePollResponse(pollResponse({ url: "/d/abc123", responseURL: sameOrigin }))).toBe(
      true,
    );
  });

  // Axios keeps GET query data in `config.params` and appends it to the wire URL itself, so
  // `config.url` can lack a query string that the browser's `responseURL` reports. Comparing
  // full hrefs read that as a redirect and navigated — silently undoing this whole guard.
  it("matches when responseURL carries a query string the request URL did not", () => {
    expect(
      isUnredirectedDownloadPagePollResponse(
        pollResponse({ url: CONTENT_PAGE_URL, responseURL: `${CONTENT_PAGE_URL}?foo=bar` }),
      ),
    ).toBe(true);
  });

  it("matches across a trailing-slash difference on the same page", () => {
    expect(isUnredirectedDownloadPagePollResponse(pollResponse({ responseURL: `${CONTENT_PAGE_URL}/` }))).toBe(true);
  });

  it("does not match a full page visit", () => {
    expect(isUnredirectedDownloadPagePollResponse(pollResponse({ headers: { "X-Inertia": "true" } }))).toBe(false);
  });

  it("does not match a response with no usable request metadata", () => {
    expect(isUnredirectedDownloadPagePollResponse(undefined)).toBe(false);
    expect(isUnredirectedDownloadPagePollResponse({})).toBe(false);
    expect(isUnredirectedDownloadPagePollResponse({ config: {} })).toBe(false);
  });

  // The gate only works because Inertia itself sets these headers on partial reloads. If an
  // Inertia upgrade renames either, the gate would silently stop matching and background polls
  // could reload the page again — so pin the names against the installed library.
  it("keys off headers the installed Inertia version actually sends", () => {
    const require = createRequire(import.meta.url);
    const inertiaCore = readFileSync(require.resolve("@inertiajs/core"), "utf8");

    expect(inertiaCore).toContain("X-Inertia-Partial-Data");
    expect(inertiaCore).toContain("X-Inertia-Partial-Component");
  });
});
