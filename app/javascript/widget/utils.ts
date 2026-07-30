import typia from "typia";

export type HeightMessage = { type: "height"; height: number };

export const parseProductURL = (href: string, customDomain?: string) => {
  try {
    const url = new URL(href);
    if (!isValidHost(url, customDomain)) return;

    // include affiliate params from the page containing the widget
    const searchParams = new URLSearchParams(window.location.search);
    const affiliateId = searchParams.get("affiliate_id") ?? searchParams.get("a");
    if (affiliateId) url.searchParams.set("affiliate_id", affiliateId);

    url.searchParams.set("referrer", window.location.href);

    if (url.host === process.env.SHORT_DOMAIN) return url;

    const matches = /\/a\/(?<affiliateId>.+)\/(?<permalink>.+)/u.exec(url.pathname);
    if (matches?.groups?.permalink && matches.groups.affiliateId) {
      url.pathname = `/l/${matches.groups.permalink}`;
      url.searchParams.set("affiliate_id", matches.groups.affiliateId);
    }

    if (!url.pathname.startsWith("/l/")) return null;

    return url;
  } catch {
    return null;
  }
};

// Match a host against a domain: the domain itself, or a subdomain of it.
//
// `endsWith` is wrong for this and was the bug: it treats the domain as a bare string suffix, so
// `notgumroad.com` and `evil-gumroad.com` both "end with" gumroad.com and passed. Anyone could
// register one and satisfy the check. Requiring the "." makes the boundary a label boundary
// instead of a character offset, which is the actual question being asked.
const isHostOrSubdomainOf = (host: string, domain: string) => host === domain || host.endsWith(`.${domain}`);

// Whether a URL is one of ours (or the seller's own storefront), used to decide which iframes the
// widget will talk to and which product URLs it will load.
//
// This is the widget's whole trust boundary — every `postMessage` handler gates on it — so it has
// to reject a host an attacker can register. Keep it a label-boundary comparison; see above.
export const isValidHost = (url: URL, customDomain?: string) =>
  isHostOrSubdomainOf(url.host, typia.assert<string>(process.env.ROOT_DOMAIN)) ||
  url.host === process.env.SHORT_DOMAIN ||
  (customDomain !== undefined && isHostOrSubdomainOf(url.host, customDomain));

export const onLoad = (cb: () => void) => {
  if (document.readyState === "complete") return cb();
  window.addEventListener("load", cb);
};
