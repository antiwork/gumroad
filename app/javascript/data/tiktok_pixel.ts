import loadTikTokPixelScript from "$vendor/tiktok_pixel";

import {
  AnalyticsConfig,
  BuyerCurrencyDisplayViewedEvent,
  GumroadEvents,
  ProductAnalyticsEvent,
} from "$app/utils/user_analytics";

export type TikTokPixelConfig = { tiktokPixelId: string | null };

type TikTokProductAnalyticsEvent = Exclude<ProductAnalyticsEvent, BuyerCurrencyDisplayViewedEvent>;

const TikTokEvents: Record<Exclude<GumroadEvents, "buyer_currency_display_viewed">, string> = {
  viewed: "ViewContent",
  iwantthis: "AddToCart",
  begin_checkout: "InitiateCheckout",
  purchased: "CompletePayment",
};

const initializedPixels = new Set<string>();

function shouldTrack() {
  return document.querySelector('meta[property="gr:tiktok_pixel:enabled"]')?.getAttribute("content") === "true";
}

export function trackProductEvent(config: AnalyticsConfig, data: TikTokProductAnalyticsEvent) {
  if (!shouldTrack() || !config.tiktokPixelId || typeof ttq === "undefined") return;

  if (data.action === "purchased") {
    if (config.trackFreeSales || data.value !== 0) {
      ttq.instance(config.tiktokPixelId).track(TikTokEvents[data.action], {
        content_id: data.permalink,
        content_type: "product",
        value: data.value / (data.valueIsSingleUnit ? 1 : 100),
        currency: data.currency,
      });
    }
  } else if (data.action === "begin_checkout") {
    if (!config.trackFreeSales && data.price === 0) return;
    ttq.instance(config.tiktokPixelId).track(TikTokEvents[data.action], {
      contents: data.products.map((product) => ({
        content_id: product.permalink,
        content_type: "product",
        quantity: product.quantity,
        price: product.price,
      })),
      value: data.price,
      currency: "USD",
      content_type: "product",
    });
  } else {
    ttq.instance(config.tiktokPixelId).track(TikTokEvents[data.action], {
      content_id: data.permalink,
      content_type: "product",
    });
  }
}

export function startTrackingForSeller(data: TikTokPixelConfig) {
  if (!shouldTrack() || !data.tiktokPixelId || initializedPixels.has(data.tiktokPixelId)) return;

  if (typeof ttq === "undefined") loadTikTokPixelScript();
  ttq.load(data.tiktokPixelId);
  ttq.instance(data.tiktokPixelId).page();
  initializedPixels.add(data.tiktokPixelId);
}
