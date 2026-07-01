import typia from "typia";

import { AnalyticsData } from "$app/parsers/product";
import { startTrackingForSeller, trackProductEvent } from "$app/utils/user_analytics";

import { addThirdPartyAnalytics } from "$app/components/useAddThirdPartyAnalytics";

// A custom HTML landing page renders as a bare wrapper document that embeds the
// seller's HTML in a sandboxed, opaque-origin iframe. Neither layer loads the
// React product page, so the seller's analytics — which normally fire from the
// product component — never run. This entry point runs only on the trusted
// wrapper (same-origin gumroad.com, under the global CSP that allowlists Google
// Analytics and the pixels) and fires the same events the standard product page
// does, so switching to a custom page keeps the same analytics event names:
//   - "viewed" on load (GA page_view + view_item, Facebook/TikTok ViewContent)
//   - "iwantthis" on buy click (GA add_to_cart, Facebook InitiateCheckout)
// begin_checkout and purchase are intentionally NOT fired here: the buy button
// navigates to the standard /checkout (which fires begin_checkout) and then the
// receipt page (which fires purchase), so firing them here would double-count.
const configElement = document.querySelector('meta[name="gr:custom-html-analytics"]');
if (configElement) {
  const props = typia.assert<{
    seller_id: string;
    analytics: AnalyticsData;
    has_product_third_party_analytics: boolean;
    third_party_analytics_domain: string;
    permalink: string;
    name: string;
  }>(JSON.parse(configElement.getAttribute("content") ?? ""));

  startTrackingForSeller(props.seller_id, props.analytics);
  trackProductEvent(props.seller_id, { permalink: props.permalink, action: "viewed", product_name: props.name });
  if (props.has_product_third_party_analytics)
    addThirdPartyAnalytics({
      domain: props.third_party_analytics_domain,
      permalink: props.permalink,
      location: "product",
    });

  // The seller's buy control lives inside the sandboxed iframe; clicking it posts
  // a "gumroad:checkout" message to this wrapper (see custom_html_wrapper_document),
  // which then navigates to checkout. That message is the custom page's equivalent
  // of the product page's "I want this" CTA, so mirror its add_to_cart tracking.
  // We re-check origin/source exactly like the wrapper's navigation handler so a
  // message from anything but the sandboxed (opaque-origin) iframe is ignored.
  const landingFrame = document.querySelector<HTMLIFrameElement>("#gumroad-landing-frame");
  window.addEventListener("message", (event) => {
    if (event.source !== landingFrame?.contentWindow || event.origin !== "null") return;
    const data: unknown = event.data;
    const isCheckout =
      data === "gumroad:checkout" || (typia.is<{ type: string }>(data) && data.type === "gumroad:checkout");
    if (!isCheckout) return;
    trackProductEvent(props.seller_id, { permalink: props.permalink, action: "iwantthis", product_name: props.name });
  });
}
