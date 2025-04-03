import loadFacebookPixelScript from "$vendor/facebook_pixel";

import { AnalyticsConfig, BeginCheckoutEvent, GumroadEvents, ProductAnalyticsEvent } from "$app/utils/user_analytics";

export type FacebookPixelConfig = { facebookPixelId: string | null };

type FacebookProductAnalyticsEvent = Exclude<ProductAnalyticsEvent, BeginCheckoutEvent>;

// Facebook only has one `"InitiateCheckout"` event that we fire when a product is added to the cart
const FacebookEvents: Record<Exclude<GumroadEvents, "begin_checkout">, string> = {
  viewed: "ViewContent",
  iwantthis: "InitiateCheckout",
  purchased: "Purchase",
};

const initializedPixels = new Set<string>();

function shouldTrack() {
  return $('meta[property="gr:fb_pixel:enabled"]').attr("content") === "true";
}

export function trackProductEvent(config: AnalyticsConfig, data: FacebookProductAnalyticsEvent) {
  if (!shouldTrack() || !config.facebookPixelId || typeof fbq === "undefined") return;

  if (data.action === "purchased") {
    if (config.trackFreeSales || data.value !== 0) {
      fbq("trackSingle", config.facebookPixelId, FacebookEvents[data.action], {
        content_ids: [data.permalink],
        content_type: "product",
        value: data.value / (data.valueIsSingleUnit ? 1 : 100), // Value in main currency unit
        currency: data.currency,
      });
    }
  } else {
    fbq("trackSingle", config.facebookPixelId, FacebookEvents[data.action], {
      content_ids: [data.permalink],
      content_type: "product",
    });
  }
}

export function startTrackingForSeller(data: FacebookPixelConfig) {
  if (!shouldTrack() || !data.facebookPixelId || initializedPixels.has(data.facebookPixelId)) return;

  loadFacebookPixelScript();
  // @ts-expect-error - Facebook Pixel type definitions are incorrect
  fbq("dataProcessingOptions", ["LDU"], 0, 0);
  fbq("init", data.facebookPixelId);
  initializedPixels.add(data.facebookPixelId);
}
