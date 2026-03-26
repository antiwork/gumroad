import loadTikTokPixelScript from "$vendor/tiktok_pixel";

import { AnalyticsConfig, BeginCheckoutEvent, GumroadEvents, ProductAnalyticsEvent } from "$app/utils/user_analytics";

export type TikTokPixelConfig = { tiktokPixelId: string | null };

type TikTokProductAnalyticsEvent = Exclude<ProductAnalyticsEvent, BeginCheckoutEvent>;

const TikTokEvents: Record<Exclude<GumroadEvents, "begin_checkout">, string> = {
  viewed: "ViewContent",
  iwantthis: "AddToCart",
  purchased: "CompletePayment",
};

const initializedPixels = new Set<string>();

function shouldTrack() {
  return $('meta[property="gr:tiktok_pixel:enabled"]').attr("content") === "true";
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
