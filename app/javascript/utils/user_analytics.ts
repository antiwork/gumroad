import * as FacebookPixel from "$app/data/facebook_pixel";
import * as GoogleAnalytics from "$app/data/google_analytics";
import { AnalyticsData } from "$app/parsers/product";

export type GumroadEvents = keyof typeof ProductEventsTitles;

export const ProductEventsTitles = {
  viewed: "viewed product",
  iwantthis: 'clicked "I want this!" button',
  begin_checkout: "started checkout",
  purchased: "purchased a product",
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
};

export type BeginCheckoutEvent = {
  action: "begin_checkout";
  seller_id: string;
  price: number;
  products: { permalink: string; name: string; quantity: number; price: number }[];
};

export type ProductAnalyticsEvent = ViewedEvent | IWantThisEvent | BeginCheckoutEvent | PurchasedEvent;

export type AnalyticsConfig = GoogleAnalytics.GoogleAnalyticsConfig &
  FacebookPixel.FacebookPixelConfig & { trackFreeSales: boolean; id: string };

const configs = new Map<string, AnalyticsConfig>();

export function startTrackingForSeller(id: string, data: AnalyticsData) {
  if (configs.has(id) || !(data.google_analytics_id || data.facebook_pixel_id)) return;
  const config: AnalyticsConfig = {
    id,
    facebookPixelId: data.facebook_pixel_id,
    googleAnalyticsId: data.google_analytics_id,
    trackFreeSales: data.free_sales,
  };
  configs.set(id, config);
  GoogleAnalytics.startTrackingForSeller(config);
  FacebookPixel.startTrackingForSeller(config);
}

export function trackProductEvent(id: string, data: ProductAnalyticsEvent) {
  const config = configs.get(id);
  if (!config) return;

  GoogleAnalytics.trackProductEvent(config, data);
  if (data.action !== "begin_checkout") FacebookPixel.trackProductEvent(config, data);
}
