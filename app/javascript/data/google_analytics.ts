import loadGoogleAnalyticsScript from "$vendor/google_analytics_4";

import { AnalyticsConfig, ProductAnalyticsEvent, ProductEventsTitles } from "$app/utils/user_analytics";

export type GoogleAnalyticsConfig = {
  googleAnalyticsId: string | null;
};

function logSellerEvent(id: string, eventName: string, payload: Record<string, unknown>) {
  gtag("event", eventName, { ...payload, send_to: `seller${id}` });
}

function logGumroadEvent(eventName: string, payload: Record<string, unknown>) {
  gtag("event", eventName, { ...payload, send_to: "gumroad" });
}

function shouldTrack() {
  return $('meta[property="gr:google_analytics:enabled"]').attr("content") === "true";
}

export function trackProductEvent(config: AnalyticsConfig, data: ProductAnalyticsEvent) {
  if (!shouldTrack() || typeof gtag === "undefined") return;

  const page = window.location.pathname + window.location.search;
  const payload = { page, title: ProductEventsTitles[data.action] };

  switch (data.action) {
    case "viewed":
      logSellerEvent(config.id, "page_view", payload);
      logSellerEvent(config.id, "view_item", {
        ...payload,
        items: [{ item_id: data.permalink, item_name: data.product_name }],
      });
      break;
    case "iwantthis":
      payload.page += `?${data.action}`;
      logSellerEvent(config.id, "page_view", payload);
      logSellerEvent(config.id, "add_to_cart", {
        ...payload,
        items: [{ item_id: data.permalink, item_name: data.product_name }],
      });
      break;
    case "begin_checkout":
      logSellerEvent(config.id, "page_view", payload);
      logSellerEvent(config.id, "begin_checkout", {
        ...payload,
        currency: "USD",
        value: data.price,
        items: data.products.map((product) => ({
          item_id: product.permalink,
          item_name: product.name,
          quantity: product.quantity,
          price: product.price,
        })),
      });
      break;
    case "purchased": {
      const value = data.value / (data.valueIsSingleUnit ? 1 : 100);
      payload.page += `?${data.action}`;
      const purchasePayload = {
        ...payload,
        items: [{ item_id: data.permalink, price: value, item_name: data.product_name, quantity: data.quantity }],
        transaction_id: data.purchase_external_id,
        affiliation: "Gumroad",
        tax: data.tax,
        currency: data.currency,
        value,
      };

      logSellerEvent(config.id, "page_view", payload);
      if (config.trackFreeSales || data.value !== 0) {
        logSellerEvent(config.id, "purchase", purchasePayload);
      }

      logGumroadEvent("purchase", purchasePayload);
      logGumroadEvent("made_sale", {
        ...purchasePayload,
        user_properties: { user_id: data.seller_id },
      });
      break;
    }
  }
}

export function startTrackingForSeller(data: AnalyticsConfig) {
  if (!shouldTrack() || !data.googleAnalyticsId) return;
  if (typeof gtag === "undefined") loadGoogleAnalyticsScript();

  gtag("config", data.googleAnalyticsId, {
    groups: `seller${data.id}`,
    cookie_flags: "SameSite=None; Secure",
    send_page_view: false,
  });
}

export function startTrackingForGumroad() {
  if (!shouldTrack()) return;
  if (typeof gtag === "undefined") loadGoogleAnalyticsScript();

  const isLoggedIn = $('meta[property="gr:logged_in_user:id"]').attr("content") !== "";
  gtag("js", new Date());
  gtag("config", "G-6LJN6D94N6", {
    groups: "gumroad",
    cookie_flags: "SameSite=None; Secure",
    dimension1: isLoggedIn ? "Logged in" : "Not logged in",
  });
}
