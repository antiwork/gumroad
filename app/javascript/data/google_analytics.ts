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
  return document.querySelector('meta[property="gr:google_analytics:enabled"]')?.getAttribute("content") === "true";
}

// Query parameters that carry single-use secrets. If these reach an analytics
// provider, anyone with access to the analytics property (or a network
// intercept of the collect request) can read a live credential — e.g. a
// password reset link (gumroad-private#1260, external security report).
const SENSITIVE_QUERY_PARAMS = ["reset_password_token", "confirmation_token", "invitation_token", "unlock_token"];

// GA4 auto-collects the full browser URL as page_location unless we override
// it. This builds the URL GA should see instead: the real URL with any
// secret-bearing query parameters removed (the parameter is dropped entirely,
// not blanked, so the value can never appear in the collect request).
export function sanitizedPageLocation(url: string = window.location.href): string {
  try {
    const parsed = new URL(url);
    for (const param of SENSITIVE_QUERY_PARAMS) parsed.searchParams.delete(param);
    return parsed.toString();
  } catch {
    // An unparseable URL shouldn't break analytics init; send nothing rather
    // than risk forwarding a token we failed to strip.
    return "";
  }
}

// GA4 also auto-collects document.referrer as page_referrer. After a
// same-origin navigation away from (say) the password reset page, the
// referrer still carries the full token-bearing URL, so it needs the same
// stripping as page_location — otherwise the secret reaches Google
// Analytics anyway via the referrer field (gumroad-private#1260).
// An empty referrer stays empty (GA treats "" as no referrer); an
// unparseable one is dropped entirely rather than forwarded unstripped.
export function sanitizedPageReferrer(referrer: string = document.referrer): string {
  if (referrer === "") return "";
  return sanitizedPageLocation(referrer);
}

// Same stripping for the relative "page" values we attach to seller/Gumroad
// events (pathname + search).
export function sanitizedPagePath(): string {
  const location = sanitizedPageLocation();
  if (location === "") return window.location.pathname;
  const parsed = new URL(location);
  return parsed.pathname + parsed.search;
}

export function trackProductEvent(config: AnalyticsConfig | undefined, data: ProductAnalyticsEvent) {
  if (!shouldTrack() || typeof gtag === "undefined") return;

  const page = sanitizedPagePath();
  const payload = { page, title: ProductEventsTitles[data.action] };

  switch (data.action) {
    case "viewed":
      if (!config) return;
      logSellerEvent(config.id, "page_view", payload);
      logSellerEvent(config.id, "view_item", {
        ...payload,
        items: [{ item_id: data.permalink, item_name: data.product_name }],
      });
      break;
    case "iwantthis":
      if (!config) return;
      payload.page += `?${data.action}`;
      logSellerEvent(config.id, "page_view", payload);
      logSellerEvent(config.id, "add_to_cart", {
        ...payload,
        items: [{ item_id: data.permalink, item_name: data.product_name }],
      });
      break;
    case "begin_checkout":
      if (!config) return;
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
        ...(data.buyer_currency_display
          ? {
              buyer_currency_shown: data.buyer_currency_display.buyer_currency_shown,
              product_currency: data.buyer_currency_display.product_currency,
              display_mode: data.buyer_currency_display.display_mode,
            }
          : {}),
      };

      if (config) logSellerEvent(config.id, "page_view", payload);
      if (config && (config.trackFreeSales || data.value !== 0)) {
        logSellerEvent(config.id, "purchase", purchasePayload);
      }

      logGumroadEvent("purchase", purchasePayload);
      logGumroadEvent("made_sale", {
        ...purchasePayload,
        user_properties: { user_id: data.seller_id },
      });
      break;
    }
    case "buyer_currency_display_viewed":
      logGumroadEvent("buyer_currency_display_view", {
        ...payload,
        product_id: data.product_id,
        buyer_currency_shown: data.buyer_currency_shown,
        product_currency: data.product_currency,
        buyer_local_price_cents: data.buyer_local_price_cents,
        rate: data.rate,
        display_mode: data.display_mode,
      });
      break;
  }
}

// The seller's GA config is registered with send_page_view: false (see
// startTrackingForSeller), so a profile view — which has no product "viewed"
// event to piggyback on — needs this explicit page_view.
export function trackProfilePageView(config: AnalyticsConfig) {
  if (!shouldTrack() || !config.googleAnalyticsId || typeof gtag === "undefined") return;

  logSellerEvent(config.id, "page_view", {
    page: sanitizedPagePath(),
    title: "viewed profile",
  });
}

export function startTrackingForSeller(data: AnalyticsConfig) {
  if (!shouldTrack() || !data.googleAnalyticsId) return;
  if (typeof gtag === "undefined") loadGoogleAnalyticsScript();

  gtag("config", data.googleAnalyticsId, {
    groups: `seller${data.id}`,
    cookie_flags: "SameSite=None; Secure",
    send_page_view: false,
    // Never let GA auto-collect a URL that could carry a secret token
    // (gumroad-private#1260). The referrer needs the same treatment: after a
    // same-origin navigation from the reset page, document.referrer still
    // holds the token-bearing URL.
    page_location: sanitizedPageLocation(),
    page_referrer: sanitizedPageReferrer(),
  });
}

export function startTrackingForGumroad() {
  if (!shouldTrack()) return;
  if (typeof gtag === "undefined") loadGoogleAnalyticsScript();

  const isLoggedIn = document.querySelector('meta[property="gr:logged_in_user:id"]')?.getAttribute("content") !== "";
  gtag("js", new Date());
  gtag("config", "G-6LJN6D94N6", {
    groups: "gumroad",
    cookie_flags: "SameSite=None; Secure",
    dimension1: isLoggedIn ? "Logged in" : "Not logged in",
    // Override GA4's automatic page_location so secret-bearing query params
    // (e.g. reset_password_token on the password reset page) are never sent
    // to Google Analytics (gumroad-private#1260). The referrer gets the same
    // treatment: after a same-origin navigation from the reset page,
    // document.referrer still holds the token-bearing URL.
    page_location: sanitizedPageLocation(),
    page_referrer: sanitizedPageReferrer(),
  });
}
