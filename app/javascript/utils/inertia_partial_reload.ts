// Inertia's default handling of a response that isn't an Inertia response (no `X-Inertia`
// header) is to hand it to the app's "invalid" listener, and ours navigates the browser to the
// response URL — effectively a full page reload.
//
// That is the right thing for a real navigation, and it stays the right thing for a background
// request that was genuinely REDIRECTED somewhere else (session expiry, revoked access): the
// buyer does need to be moved off the page. It is wrong only for a background request that came
// back as non-Inertia content FROM THE URL IT ASKED FOR — an edge challenge page, a proxy error
// page, a captive-portal interception. There, navigating means reloading the same URL, which
// re-issues the request that was just intercepted, and the buyer loses a long viewing session
// for what should have been a recoverable blip.
// See https://github.com/antiwork/gumroad/issues/4007 and gumroad-private#1400.
//
// So the guard is deliberately narrow, and both halves have to hold:
//   1. the request was a background partial reload — `X-Inertia-Partial-Data` is only set when
//      the visit asked for a subset of props, which is what `usePoll` and any other
//      `only:`-scoped reload does; and
//   2. no redirect happened — the response came back from the same URL the request went to, so
//      navigating there would just repeat the request.
// A partial reload that WAS redirected still navigates, exactly as before this guard existed.
const PARTIAL_DATA_HEADER = "x-inertia-partial-data";

const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null;

const stringOrNull = (value: unknown): string | null => (typeof value === "string" && value !== "" ? value : null);

const isPartialReload = (config: Record<string, unknown>): boolean => {
  const { headers } = config;
  if (!isRecord(headers)) return false;

  // Axios normalizes headers into an AxiosHeaders instance, which exposes a case-insensitive
  // `has`. The config can also carry a plain object, so handle both shapes.
  const { has } = headers;
  if (typeof has === "function") return Boolean(has.call(headers, PARTIAL_DATA_HEADER));

  return Object.keys(headers).some((name) => name.toLowerCase() === PARTIAL_DATA_HEADER);
};

// True when the response came back from a different page than the request was sent to, i.e. the
// server (or the edge) redirected it somewhere else. `responseURL` is the final URL after the
// browser followed any redirects, so comparing it to the requested URL detects one having
// happened without needing to see the intermediate 3xx.
//
// Only origin + path are compared, deliberately. Axios keeps GET query data in `config.params`
// and appends it to the wire URL itself, so `config.url` can lack a query string that
// `responseURL` reports — comparing full hrefs would read that as a redirect and navigate,
// which is the exact bug this guard exists to prevent. A redirect that actually matters here
// (session expiry, revoked access) always lands on a different path.
const wasRedirected = (config: Record<string, unknown>, request: unknown): boolean => {
  const requestedUrl = stringOrNull(config.url);
  const finalUrl = isRecord(request) ? stringOrNull(request.responseURL) : null;
  if (requestedUrl === null || finalUrl === null) return false;

  const pageIdentity = (url: string) => {
    const { origin, pathname } = new URL(url, window.location.origin);
    // Ignore a trailing slash so "/d/abc" and "/d/abc/" are the same page.
    return `${origin}${pathname.replace(/\/$/u, "")}`;
  };

  try {
    return pageIdentity(finalUrl) !== pageIdentity(requestedUrl);
  } catch {
    // Unparseable URL: fall back to treating it as a redirect so navigation still happens. The
    // safe default here is the pre-existing behavior, never silently swallowing the response.
    return true;
  }
};

/**
 * True for a background partial reload whose response came back, non-Inertia, from the URL it
 * asked for — the one case where navigating would re-trigger whatever intercepted it.
 *
 * `response` is an axios response; typed loosely because Inertia raises the "invalid" event
 * from plain JS.
 */
export const isUnredirectedPartialReloadResponse = (response: unknown): boolean => {
  if (!isRecord(response)) return false;
  const { config, request } = response;
  if (!isRecord(config)) return false;

  return isPartialReload(config) && !wasRedirected(config, request);
};
