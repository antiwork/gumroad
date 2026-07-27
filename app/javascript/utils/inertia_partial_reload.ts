// Inertia's default handling of a response that isn't an Inertia response (no `X-Inertia`
// header) is to hand it to the app's "invalid" listener, and ours navigates the browser to the
// response URL — effectively a full page reload.
//
// That is the right thing for a real navigation, and it stays the right thing for a background
// request that was genuinely REDIRECTED somewhere else (session expiry, revoked access): the
// buyer does need to be moved off the page. It is wrong only for the buyer content page's
// timer-driven polls coming back as non-Inertia content FROM THE URL THEY ASKED FOR — an edge
// challenge page, a proxy error page, a captive-portal interception. There, navigating means
// reloading the same URL, which re-issues the request that was just intercepted, and the buyer
// loses a long viewing session for what should have been a recoverable blip.
// See https://github.com/antiwork/gumroad/issues/4007 and gumroad-private#1400.
//
// The guard is deliberately narrow, and matches EXACTLY the boundary the server already defines
// in `UrlRedirectsController#download_page_polling_request?`. All four have to hold:
//   1. the request was a GET — a poll never mutates anything, so a non-Inertia answer to a form
//      submission, search, or any other write must keep the old navigating behavior;
//   2. the visit targeted the buyer content page — `X-Inertia-Partial-Component` names the
//      component a partial reload is scoped to, and only `UrlRedirects/DownloadPage` polls;
//   3. every requested prop is one of the content page's polling props (`audio_durations`,
//      `latest_media_locations`). Inertia sets `X-Inertia-Partial-Data` for EVERY `only:` visit,
//      of which there are dozens across the app, so the header alone is not a poll marker; and
//   4. no redirect happened — the response came back from the same URL the request went to, so
//      navigating there would just repeat the request.
// Anything failing any of these — including a content-page partial reload that WAS redirected —
// navigates exactly as it did before this guard existed.
const PARTIAL_DATA_HEADER = "x-inertia-partial-data";
const PARTIAL_COMPONENT_HEADER = "x-inertia-partial-component";

// Kept in lockstep with `DOWNLOAD_PAGE_POLLING_PROPS` and the partial-component check in
// app/controllers/url_redirects_controller.rb. The server decides what counts as a poll; this
// is the client recognizing the same set so it can drop exactly those responses and no others.
const DOWNLOAD_PAGE_COMPONENT = "UrlRedirects/DownloadPage";
const DOWNLOAD_PAGE_POLLING_PROPS = ["audio_durations", "latest_media_locations"];

const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null;

const stringOrNull = (value: unknown): string | null => (typeof value === "string" && value !== "" ? value : null);

// Axios normalizes request headers into an AxiosHeaders instance, which exposes a
// case-insensitive `get`. The config can also carry a plain object, so handle both shapes.
const headerValue = (headers: unknown, name: string): string | null => {
  if (!isRecord(headers)) return null;

  const { get } = headers;
  if (typeof get === "function") return stringOrNull(get.call(headers, name));

  const match = Object.keys(headers).find((key) => key.toLowerCase() === name);
  return match === undefined ? null : stringOrNull(headers[match]);
};

const isGet = (config: Record<string, unknown>): boolean => {
  const method = stringOrNull(config.method);
  // Inertia always sets a method; treat an absent one as "not provably a GET" rather than
  // assuming the safe-looking case.
  return method !== null && method.toLowerCase() === "get";
};

// True only for a partial reload of the buyer content page that asked for nothing beyond its
// polling props. A partial reload of any other component, or one of the content page's own
// `only:` visits that asks for something else, is not a poll and is left alone.
const isDownloadPagePoll = (config: Record<string, unknown>): boolean => {
  const { headers } = config;
  if (headerValue(headers, PARTIAL_COMPONENT_HEADER) !== DOWNLOAD_PAGE_COMPONENT) return false;

  const partialData = headerValue(headers, PARTIAL_DATA_HEADER);
  if (partialData === null) return false;

  const requestedProps = partialData.split(",").map((prop) => prop.trim());
  return requestedProps.every((prop) => DOWNLOAD_PAGE_POLLING_PROPS.includes(prop));
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
 * True for a buyer-content-page background poll whose response came back, non-Inertia, from the
 * URL it asked for — the one case where navigating would re-trigger whatever intercepted it.
 *
 * `response` is an axios response; typed loosely because Inertia raises the "invalid" event
 * from plain JS.
 */
export const isUnredirectedDownloadPagePollResponse = (response: unknown): boolean => {
  if (!isRecord(response)) return false;
  const { config, request } = response;
  if (!isRecord(config)) return false;

  return isGet(config) && isDownloadPagePoll(config) && !wasRedirected(config, request);
};

// Dropping a response is invisible by design: the page keeps showing what it already has. That
// makes an ongoing interception look like nothing more than progress that stopped updating, which
// is very hard to diagnose from a buyer's bug report. So leave one console breadcrumb saying which
// page was affected.
//
// The breadcrumb must NOT contain the content URL itself. A buyer content page lives at
// `/d/:token`, and that token is the credential: anyone holding it can read the purchased files.
// The whole point of this warning is that a buyer copies it into a support ticket, so anything it
// prints ends up in a shared inbox. So the path is reduced to its shape (`/d/[redacted]`) and the
// query string and fragment are dropped entirely — enough to say "a content-page poll is being
// intercepted", nothing that grants access. Support can still identify the buyer from the ticket.
//
// Every path segment after the first is redacted rather than only the token, because other pages
// that could reach this code path (`/d/:token/:file_id`, and anything added later) put identifiers
// in those positions too. Redacting by position means a new route cannot quietly start leaking.
const redactUrlForLogging = (url: string): string => {
  try {
    const { pathname } = new URL(url, window.location.origin);
    const segments = pathname.split("/").filter((segment) => segment !== "");
    if (segments.length === 0) return "/";
    return `/${[segments[0], ...segments.slice(1).map(() => "[redacted]")].join("/")}`;
  } catch {
    // Unparseable URL: say nothing about it rather than risk printing a raw token.
    return "[redacted]";
  }
};

// The poll runs every few seconds, and an interception usually persists for as long as whatever
// caused it, so logging every drop would bury the console in identical lines. One warning per URL
// per page load is enough to answer "is this page silently dropping polls?" — the URLs seen so far
// live here and reset naturally when the page is reloaded. This set is keyed on the FULL url so two
// genuinely different pages each get their own warning; it is only ever compared, never logged.
const alreadyWarnedUrls = new Set<string>();

/**
 * Warns once per URL that a background poll response was dropped. Safe to call on every drop.
 * The warning names only the redacted path shape — never the content token or query string.
 *
 * `response` is the same axios response passed to `isUnredirectedDownloadPagePollResponse`.
 */
export const warnAboutDroppedPollResponse = (response: unknown): void => {
  if (!isRecord(response)) return;
  const { config, request } = response;

  // Prefer the URL the browser actually ended on; fall back to the one the request asked for.
  const requestedUrl =
    (isRecord(request) ? stringOrNull(request.responseURL) : null) ??
    (isRecord(config) ? stringOrNull(config.url) : null);
  if (requestedUrl === null || alreadyWarnedUrls.has(requestedUrl)) return;

  alreadyWarnedUrls.add(requestedUrl);
  // eslint-disable-next-line no-console
  console.warn(
    `Dropped a non-Inertia response to a background content-page poll of ${redactUrlForLogging(requestedUrl)} (path redacted on purpose — it is not safe to share). Something between the browser and Gumroad answered the poll with its own page (an edge challenge, a proxy error, a captive portal). The page keeps what it already loaded and the poll keeps retrying; further drops for this page are not logged.`,
  );
};
