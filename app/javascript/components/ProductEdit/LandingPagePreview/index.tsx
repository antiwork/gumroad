import * as React from "react";
import typia from "typia";

import { writeQueryParams } from "$app/utils/url";

// Loads the same /l/:id/landing endpoint buyers see. The sandbox omits
// top-navigation (mirrors the production wrapper) so the seller's HTML can't
// navigate the dashboard tab. The buy button posts a "gumroad:checkout"
// message to this parent, which opens checkout in a new tab so the seller can
// test the button without being yanked out of the editor.
//
// Accepts both the legacy string form and the structured form the interpolator
// now always emits — `{type:"gumroad:checkout", params:{...}}` — so a buy
// element that advertises a specific variant/quantity/price/recurrence opens
// the right pre-selected checkout in the preview, matching what buyers see.
const ALLOWED_CHECKOUT_KEYS = ["variant", "option", "quantity", "price", "recurrence"] as const;

const buildCheckoutUrl = (uniquePermalink: string, params: Record<string, unknown> | undefined): string => {
  const url = new URL(`/l/${encodeURIComponent(uniquePermalink)}?wanted=true`, window.location.origin);
  if (params) {
    const values: Record<string, string | null> = {};
    for (const key of ALLOWED_CHECKOUT_KEYS) {
      const v = params[key];
      values[key] = v == null || v === "" ? null : String(v);
    }
    writeQueryParams(url, values);
  }
  return url.pathname + url.search;
};

export const LandingPagePreview = ({
  uniquePermalink,
  storeHostnames,
}: {
  uniquePermalink: string;
  storeHostnames: string[];
}) => {
  const frameRef = React.useRef<HTMLIFrameElement>(null);

  React.useEffect(() => {
    const onMessage = (e: MessageEvent) => {
      // Only our own iframe can request checkout — gate on e.source so another
      // window can't drive the dashboard. The iframe's sandbox has no
      // allow-same-origin, so e.origin is "null" and isn't a usable check.
      if (e.source !== frameRef.current?.contentWindow) return;

      let params: Record<string, unknown> | undefined;
      if (e.data === "gumroad:checkout") {
        params = undefined;
      } else if (typia.is<{ type: "gumroad:checkout"; params?: Record<string, unknown> }>(e.data)) {
        params = e.data.params;
      } else if (typia.is<{ type: "gumroad:navigate"; url: string }>(e.data)) {
        // A link to one of the seller's own Gumroad pages. In production the
        // trusted wrapper navigates the buyer's tab after checking the URL
        // against the seller's own hostnames. Here the seller is previewing
        // their own page from the editor, so open a new tab for the same
        // reason checkout does — so they aren't yanked out of the editor.
        //
        // The message is only as trustworthy as the HTML that sent it, which
        // the seller wrote, so apply the same two checks the public wrapper
        // does: http(s) only (a page can't turn a click into javascript:/data:)
        // and the destination host must be one the seller controls. Without the
        // host check any script on the page could pop open an arbitrary site
        // from inside the Gumroad dashboard.
        let destination;
        try {
          destination = new URL(e.data.url, window.location.origin);
        } catch {
          return;
        }
        if (destination.protocol !== "https:" && destination.protocol !== "http:") return;
        if (!storeHostnames.includes(destination.hostname)) return;
        window.open(destination.href, "_blank", "noopener");
        return;
      } else {
        return;
      }

      window.open(buildCheckoutUrl(uniquePermalink, params), "_blank", "noopener");
    };
    window.addEventListener("message", onMessage);
    return () => window.removeEventListener("message", onMessage);
  }, [uniquePermalink, storeHostnames]);

  return (
    <iframe
      ref={frameRef}
      title="Landing page preview"
      src={`/l/${encodeURIComponent(uniquePermalink)}/landing/embed`}
      sandbox="allow-scripts allow-forms allow-downloads"
      referrerPolicy="no-referrer"
      className="h-[75vh] min-h-150 w-full rounded border border-border bg-white"
    />
  );
};
