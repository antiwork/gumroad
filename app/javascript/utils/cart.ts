import typia from "typia";

import { CardProduct } from "$app/parsers/product";

import { CartItem } from "$app/components/Checkout/cartState";

export type CartItemsCount = number | "not-available";

let countPromise: Promise<CartItemsCount> | null = null;

// The count is read from the storefront host when that host shares the root domain's cart cookie,
// and from the root domain on a custom domain (which does not, and where the checkout button sends
// buyers anyway).
export const cartItemsCountIsSameOrigin = () => {
  const { host } = window.location;
  const rootHost = new URL(Routes.cart_items_count_url(), window.location.href).host;
  return host === rootHost || host.endsWith(`.${rootHost}`);
};

export const cartItemsCountSrc = () =>
  cartItemsCountIsSameOrigin() ? Routes.cart_items_count_path() : Routes.cart_items_count_url();

// "not-available" means the count could not be read, which is not the same as having items in the
// cart: treating it as truthy shows the cart shortcut to every visitor whose count is unreadable.
export const hasCartItems = (count: CartItemsCount | null): count is number => typeof count === "number" && count > 0;

// A same-origin count is fetched from the page itself: the page's own request carries the cart
// cookie, while a frame only gets it when the browser grants the frame storage access.
const readSameOriginCount = (): Promise<CartItemsCount> =>
  fetch(Routes.cart_items_count_path(), { headers: { Accept: "application/json" }, cache: "no-store" })
    .then((response) => (response.ok ? response.json() : Promise.reject(new Error("count unavailable"))))
    .then((body) => (typia.is<{ cart_items_count: number }>(body) ? body.cart_items_count : "not-available"))
    .catch(() => "not-available");

const readCountFromFrame = (src: string, resolve: (value: CartItemsCount) => void) => {
  const iframe = document.createElement("iframe");
  iframe.style.display = "none";
  iframe.src = src;
  const { origin } = new URL(src, window.location.href);
  const handler = (evt: MessageEvent) => {
    if (evt.source !== iframe.contentWindow || evt.origin !== origin) return;

    if (typia.is<{ type: "cart-items-count"; cartItemsCount: CartItemsCount }>(evt.data)) {
      window.removeEventListener("message", handler);
      iframe.remove();
      resolve(evt.data.cartItemsCount);
    }
  };
  window.addEventListener("message", handler);
  document.body.appendChild(iframe);
};

export const loadCartItemsCount = (src: string, cb: (value: CartItemsCount) => void) => {
  if (!countPromise)
    countPromise = new Promise((resolve) => {
      if (cartItemsCountIsSameOrigin()) void readSameOriginCount().then(resolve);
      else readCountFromFrame(src, resolve);
    });
  void countPromise.then(cb);
};

export const PLACEHOLDER_CART_ITEM: CartItem = {
  product: {
    id: "",
    permalink: "",
    name: "A Sample Product",
    creator: { name: "Gumroadian", profile_url: "", avatar_url: "", id: "" },
    url: "",
    thumbnail_url: "",
    currency_code: "usd",
    price_cents: 100,
    quantity_remaining: null,
    pwyw: null,
    installment_plan: null,
    is_preorder: false,
    is_tiered_membership: false,
    is_legacy_subscription: false,
    is_multiseat_license: false,
    is_quantity_enabled: false,
    free_trial: null,
    options: [],
    recurrences: null,
    duration_in_months: null,
    native_type: "digital",
    custom_fields: [],
    require_shipping: false,
    supports_paypal: null,
    paypal_card_funding_disabled: false,
    has_offer_codes: false,
    analytics: {
      google_analytics_id: null,
      facebook_pixel_id: null,
      tiktok_pixel_id: null,
      free_sales: false,
    },
    has_tipping_enabled: true,
    exchange_rate: 1,
    rental: null,
    shippable_country_codes: [],
    ppp_details: null,
    upsell: null,
    cross_sells: [],
    archived: false,
    bundle_products: [],
    can_gift: true,
  },
  price: 100,
  quantity: 1,
  recurrence: null,
  option_id: null,
  recommended_by: null,
  affiliate_id: null,
  rent: false,
  url_parameters: {},
  referrer: "",
  recommender_model_name: null,
  accepted_offer: null,
  call_start_time: null,
  pay_in_installments: false,
  force_new_subscription: false,
};

export const PLACEHOLDER_CARD_PRODUCT: CardProduct = {
  id: "",
  permalink: "",
  name: "A Sample Product",
  seller: { id: "", name: "Gumroadian", profile_url: "", avatar_url: "", is_verified: false },
  ratings: null,
  price_cents: 100,
  currency_code: "usd",
  thumbnail_url: null,
  native_type: "digital",
  url: "",
  is_pay_what_you_want: false,
  quantity_remaining: null,
  is_sales_limited: false,
  duration_in_months: null,
  recurrence: null,
};
