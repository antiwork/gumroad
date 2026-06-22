import typia from "typia";

import * as FacebookPixel from "$app/data/facebook_pixel";
import * as GoogleAnalytics from "$app/data/google_analytics";
import * as TikTokPixel from "$app/data/tiktok_pixel";
import { AnalyticsData, BuyerCurrencyDisplay } from "$app/parsers/product";
import { CurrencyCode, getIsSingleUnitCurrency } from "$app/utils/currency";

export type GumroadEvents = keyof typeof ProductEventsTitles;

export const ProductEventsTitles = {
  viewed: "viewed product",
  iwantthis: 'clicked "I want this!" button',
  begin_checkout: "started checkout",
  purchased: "purchased a product",
  buyer_currency_display_viewed: "viewed buyer currency display",
};

type ViewedEvent = { action: "viewed"; permalink: string; product_name: string };

type IWantThisEvent = { action: "iwantthis"; permalink: string; product_name: string };

type PurchasedEvent = {
  action: "purchased";
  permalink: string;
  purchase_external_id: string;
  seller_id: string;
  product_name: string;
  value: number;
  valueIsSingleUnit: boolean;
  currency: string;
  quantity: number;
  tax: string;
  buyer_currency_display?: BuyerCurrencyDisplay;
};

export type BeginCheckoutEvent = {
  action: "begin_checkout";
  seller_id: string;
  price: number;
  products: { permalink: string; name: string; quantity: number; price: number }[];
};

export type BuyerCurrencyDisplayViewedEvent = BuyerCurrencyDisplay & { action: "buyer_currency_display_viewed" };

export type ProductAnalyticsEvent =
  | ViewedEvent
  | IWantThisEvent
  | BeginCheckoutEvent
  | PurchasedEvent
  | BuyerCurrencyDisplayViewedEvent;

export type AnalyticsConfig = GoogleAnalytics.GoogleAnalyticsConfig &
  FacebookPixel.FacebookPixelConfig &
  TikTokPixel.TikTokPixelConfig & { trackFreeSales: boolean; id: string };

const configs = new Map<string, AnalyticsConfig>();

export function startTrackingForSeller(id: string, data: AnalyticsData) {
  if (configs.has(id) || !(data.google_analytics_id || data.facebook_pixel_id || data.tiktok_pixel_id)) return;
  const config: AnalyticsConfig = {
    id,
    facebookPixelId: data.facebook_pixel_id,
    googleAnalyticsId: data.google_analytics_id,
    tiktokPixelId: data.tiktok_pixel_id,
    trackFreeSales: data.free_sales,
  };
  configs.set(id, config);
  GoogleAnalytics.startTrackingForSeller(config);
  FacebookPixel.startTrackingForSeller(config);
  TikTokPixel.startTrackingForSeller(config);
}

export function trackProductEvent(id: string | undefined, data: ProductAnalyticsEvent) {
  const config = id ? configs.get(id) : undefined;

  if (data.action === "buyer_currency_display_viewed") {
    GoogleAnalytics.trackProductEvent(config, data);
    return;
  }

  if (!config) return;

  GoogleAnalytics.trackProductEvent(config, data);
  if (data.action !== "begin_checkout") FacebookPixel.trackProductEvent(config, data);
  if (data.action !== "begin_checkout") TikTokPixel.trackProductEvent(config, data);
}

export type SellerPurchaseEvent = {
  permalink: string;
  purchase_external_id: string;
  product_name: string;
  value: number;
  currency: string;
  quantity: number;
  tax: string;
  buyer_currency_display?: BuyerCurrencyDisplay;
};

export type SellerAnalyticsProps = {
  seller_id: string;
  analytics: AnalyticsData;
  purchase_event: SellerPurchaseEvent;
};

export function trackSellerPurchaseEvent({ seller_id, analytics, purchase_event }: SellerAnalyticsProps) {
  startTrackingForSeller(seller_id, analytics);
  trackProductEvent(seller_id, {
    action: "purchased",
    seller_id,
    permalink: purchase_event.permalink,
    purchase_external_id: purchase_event.purchase_external_id,
    product_name: purchase_event.product_name,
    value: purchase_event.value,
    valueIsSingleUnit: getIsSingleUnitCurrency(typia.assert<CurrencyCode>(purchase_event.currency)),
    currency: purchase_event.currency.toUpperCase(),
    quantity: purchase_event.quantity,
    tax: purchase_event.tax,
    ...(purchase_event.buyer_currency_display ? { buyer_currency_display: purchase_event.buyer_currency_display } : {}),
  });
}

export function trackBuyerCurrencyDisplayView(id: string | undefined, data: BuyerCurrencyDisplay | undefined) {
  if (!data) return;
  if (data.display_mode !== "buyer_local") return;

  let alreadyTracked = false;
  try {
    const key = `bcd_view_${data.product_id}`;
    alreadyTracked = window.sessionStorage.getItem(key) !== null;
    if (!alreadyTracked) window.sessionStorage.setItem(key, "true");
  } catch {
    alreadyTracked = false;
  }
  if (alreadyTracked) return;

  trackProductEvent(id, {
    action: "buyer_currency_display_viewed",
    ...data,
  });
}
