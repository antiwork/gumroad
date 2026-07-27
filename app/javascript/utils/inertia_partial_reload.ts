// Inertia's default handling of a response that isn't an Inertia response (no `X-Inertia`
// header) is to hand it to the app's "invalid" listener, and ours navigates the browser to the
// response URL — effectively a full page reload of the current page.
//
// That is the right thing for a real navigation (e.g. the server redirected us to a page that
// isn't Inertia-rendered), but it is destructive for a BACKGROUND partial reload. The buyer
// content page refreshes small slices of its props on a timer while the buyer is on the page
// (audio durations, media positions). If one of those background requests comes back as plain
// HTML — an edge challenge page, an error page from a proxy, a captive-portal interception on
// the buyer's network — reloading the page throws away everything the buyer had going: the
// video player is torn down and they lose their place in a long video.
// See https://github.com/antiwork/gumroad/issues/4007 and gumroad-private#1400.
//
// A background partial reload is identifiable from the request headers Inertia itself sets:
// `X-Inertia-Partial-Data` is only present when the visit asked for a subset of props, which is
// what `usePoll` and any other `only:`-scoped reload does.
const PARTIAL_DATA_HEADER = "x-inertia-partial-data";

const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null;

/** `response` is an axios response; typed loosely because the Inertia "invalid" event is raised from plain JS. */
export const isPartialReloadResponse = (response: unknown): boolean => {
  if (!isRecord(response)) return false;
  const { config } = response;
  if (!isRecord(config)) return false;
  const { headers } = config;
  if (!isRecord(headers)) return false;

  // Axios normalizes headers into an AxiosHeaders instance, which exposes a case-insensitive
  // `has`. The config can also carry a plain object, so handle both shapes.
  const { has } = headers;
  if (typeof has === "function") return Boolean(has.call(headers, PARTIAL_DATA_HEADER));

  return Object.keys(headers).some((name) => name.toLowerCase() === PARTIAL_DATA_HEADER);
};
