import typia from "typia";

import { AnalyticsData } from "$app/parsers/product";
import { startTrackingForSeller, trackSellerPageView } from "$app/utils/user_analytics";

// A custom HTML profile page renders as a bare wrapper document that embeds the
// seller's HTML in a sandboxed, opaque-origin iframe. Neither layer loads the
// React profile page, so the seller's account-scoped analytics never run. This
// entry point runs only on the trusted wrapper (same-origin gumroad.com, under
// the global CSP that allowlists Google Analytics and the pixels) — the profile
// counterpart of custom_html_analytics.ts (#5658).
//
// A profile has no permalink, product name, or buy action, so unlike the
// product entry point this one only bootstraps the pixels and fires a seller GA
// page_view — no view_item/ViewContent and no checkout-message listener. That
// matches the standard profile page, which fires no product-shaped events of
// its own either (only an embedded featured product does, and a custom HTML
// profile has none).
const configElement = document.querySelector('meta[name="gr:custom-html-profile-analytics"]');
if (configElement) {
  const props = typia.assert<{
    seller_id: string;
    analytics: AnalyticsData;
    third_party_analytics_url: string | null;
  }>(JSON.parse(configElement.getAttribute("content") ?? ""));

  startTrackingForSeller(props.seller_id, props.analytics);
  trackSellerPageView(props.seller_id);

  // Universal ("run everywhere") raw snippets load in a hidden iframe on the
  // cookie-less third-party analytics domain, like addThirdPartyAnalytics does
  // for products — but that helper builds a product-permalink URL, so the
  // wrapper receives the profile-keyed URL from the backend instead. The
  // wrapper document has no stylesheet, so hide the iframe inline.
  if (props.third_party_analytics_url) {
    const iframe = document.createElement("iframe");
    iframe.style.display = "none";
    iframe.setAttribute("sandbox", "allow-scripts allow-same-origin");
    iframe.ariaLabel = "Third-party analytics";
    iframe.setAttribute("src", props.third_party_analytics_url);
    document.body.appendChild(iframe);
  }
}
