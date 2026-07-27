// @vitest-environment happy-dom
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { afterEach, describe, expect, it, vi } from "vitest";

import {
  isUnredirectedDownloadPagePollResponse,
  warnAboutDroppedPollResponse,
} from "$app/utils/inertia_partial_reload";

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

// A dropped response leaves no trace on the page — the buyer just sees values that stop updating.
// The console breadcrumb is the only way to tell that apart from a page that is simply idle, so it
// has to say which page was affected, and it has to stay quiet enough that a poll firing every few
// seconds does not flood the console.
//
// It also has to be safe to paste into a support ticket, which is the whole reason it exists. The
// content URL is `/d/:token`, and that token is the credential for the purchased files, so the
// warning names only the shape of the path — never the token, and never the query string.
describe("warnAboutDroppedPollResponse", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  const warnings = () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    return () => warn.mock.calls.map((call) => String(call[0]));
  };

  it("says which page was affected without printing the content token", () => {
    const logged = warnings();
    const url = `${CONTENT_PAGE_URL}-named`;

    warnAboutDroppedPollResponse(pollResponse({ url, responseURL: url }));

    expect(logged()).toHaveLength(1);
    expect(logged()[0]).toContain("/d/[redacted]");
    expect(logged()[0]).not.toContain("abc123");
    expect(logged()[0]).not.toContain(url);
  });

  // The token can arrive in any position a route puts an identifier in, and a poll URL carries
  // query parameters of its own. None of it may reach the console.
  it("keeps tokens and query parameters out of the warning", () => {
    const logged = warnings();
    const url = "https://gumroad.com/d/s3cr3t-token/file-9f8e7d?email=buyer%40example.com&purchase_id=t0ps3cr3t#anchor";

    warnAboutDroppedPollResponse(pollResponse({ url, responseURL: url }));

    expect(logged()).toHaveLength(1);
    const warning = logged()[0] ?? "";
    expect(warning).toContain("/d/[redacted]/[redacted]");
    for (const secret of [
      "s3cr3t-token",
      "file-9f8e7d",
      "buyer",
      "example.com",
      "purchase_id",
      "t0ps3cr3t",
      "anchor",
    ]) {
      expect(warning).not.toContain(secret);
    }
    expect(warning).not.toContain("?");
    expect(warning).not.toContain("#");
  });

  it("warns only once for the same URL, however many polls are dropped", () => {
    const logged = warnings();
    const url = `${CONTENT_PAGE_URL}-repeat`;
    const dropped = pollResponse({ url, responseURL: url });

    warnAboutDroppedPollResponse(dropped);
    warnAboutDroppedPollResponse(dropped);
    warnAboutDroppedPollResponse(dropped);

    expect(logged()).toHaveLength(1);
  });

  // Dedupe is keyed on the full URL, which is never logged, so two genuinely different pages each
  // get their own warning even though both are reported redacted.
  it("warns again for a different URL", () => {
    const logged = warnings();
    const first = `${CONTENT_PAGE_URL}-one`;
    const second = `${CONTENT_PAGE_URL}-two`;

    warnAboutDroppedPollResponse(pollResponse({ url: first, responseURL: first }));
    warnAboutDroppedPollResponse(pollResponse({ url: second, responseURL: second }));

    expect(logged()).toHaveLength(2);
  });

  // Falls back to the requested URL so a response with no `responseURL` still says which page was
  // affected, and stays silent rather than logging a useless "undefined" line when neither exists.
  it("falls back to the requested URL, and says nothing when there is no URL at all", () => {
    const logged = warnings();
    const url = `${CONTENT_PAGE_URL}-fallback`;

    warnAboutDroppedPollResponse({ config: { url }, request: {} });
    expect(logged()).toHaveLength(1);
    expect(logged()[0]).toContain("/d/[redacted]");
    expect(logged()[0]).not.toContain(url);

    warnAboutDroppedPollResponse({ config: {}, request: {} });
    warnAboutDroppedPollResponse(undefined);
    expect(logged()).toHaveLength(1);
  });

  // A URL the browser cannot parse must not be echoed verbatim as a "best effort" — that is exactly
  // where a raw token would slip through.
  it("reports an unparseable URL as fully redacted", () => {
    const logged = warnings();

    warnAboutDroppedPollResponse({ config: { url: "http://[not-a-url/d/s3cr3t" }, request: {} });

    expect(logged()).toHaveLength(1);
    expect(logged()[0]).toContain("[redacted]");
    expect(logged()[0]).not.toContain("s3cr3t");
  });
});
