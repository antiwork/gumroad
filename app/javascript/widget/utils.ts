import { cast } from "ts-safe-cast";

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

export const isValidHost = (url: URL, customDomain?: string) =>
  url.host.endsWith(cast(process.env.ROOT_DOMAIN)) ||
  url.host === process.env.SHORT_DOMAIN ||
  (customDomain && url.host.endsWith(customDomain));

export const onLoad = (cb: () => void) => {
  if (document.readyState === "complete") return cb();
  window.addEventListener("load", cb);
};
