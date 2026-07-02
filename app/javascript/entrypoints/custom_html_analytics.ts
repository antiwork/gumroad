import typia from "typia";

import { AnalyticsData } from "$app/parsers/product";
import { startTrackingForSeller, trackProductEvent, trackProfilePageView } from "$app/utils/user_analytics";

import { addProfileThirdPartyAnalytics, addThirdPartyAnalytics } from "$app/components/useAddThirdPartyAnalytics";

type SharedProps = {
  seller_id: string;
  analytics: AnalyticsData;
  third_party_analytics_domain: string;
};

// Emitted by LinksController#custom_html_analytics_head for a custom product
// landing page.
type ProductProps = SharedProps & {
  has_product_third_party_analytics: boolean;
  permalink: string;
  name: string;
};

// Emitted by UsersController#profile_custom_html_analytics_head for a custom
// profile landing page, which has no product: no permalink/name and no
// checkout bridge, only the seller's universal snippets.
type ProfileProps = SharedProps & {
  has_universal_third_party_analytics: boolean;
  // Ruby emits the block whenever a pixel id is configured, even when the
  // seller has no username (username -> JSON null). Universal snippets — the
  // only consumer of username below — require username.present? server-side,
  // so a null username here always coincides with has_universal = false.
  username: string | null;
};

// A custom HTML landing page renders as a bare wrapper document that embeds the
// seller's HTML in a sandboxed, opaque-origin iframe. Neither layer loads the
// React product/profile page, so the seller's analytics — which normally fire
// from those components — never run. This entry point runs only on the trusted
// wrapper (same-origin gumroad.com, under the global CSP that allowlists Google
// Analytics and the pixels) and fires the same events the standard page does.
//
// For a product landing page, that keeps the same analytics event names:
//   - "viewed" on load (GA page_view + view_item, Facebook/TikTok ViewContent)
//   - "iwantthis" on buy click (GA add_to_cart, Facebook InitiateCheckout)
// begin_checkout and purchase are intentionally NOT fired here: the buy button
// navigates to the standard /checkout (which fires begin_checkout) and then the
// receipt page (which fires purchase), so firing them here would double-count.
//
// For a profile landing page, only a page view fires — a profile has no buy
// affordance, so there are no product or e-commerce events.
const configElement = document.querySelector('meta[name="gr:custom-html-analytics"]');
if (configElement) {
  const props = typia.assert<ProductProps | ProfileProps>(JSON.parse(configElement.getAttribute("content") ?? ""));

  startTrackingForSeller(props.seller_id, props.analytics);

  if ("permalink" in props) {
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
  } else {
    trackProfilePageView(props.seller_id);
    if (props.has_universal_third_party_analytics && props.username != null)
      addProfileThirdPartyAnalytics({ domain: props.third_party_analytics_domain, username: props.username });
  }
}
