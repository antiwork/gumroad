import { type AnalyticsData } from "$app/parsers/product";
import { type BeginCheckoutEvent } from "$app/utils/user_analytics";

import {
  type CartItem,
  type CartState,
  convertToUSD,
  findCartItem,
  getDiscountedPrice,
  newCartState,
  type ProductToAdd,
} from "$app/components/Checkout/cartState";

// Query-string params that Gumroad consumes itself and should NOT be forwarded
// as arbitrary product url_parameters.
const GUMROAD_PARAMS = [
  "product",
  "option",
  "recurrence",
  "quantity",
  "price",
  "recommended_by",
  "affiliate_id",
  "referrer",
  "rent",
  "recommender_model_name",
  "call_start_time",
  "pay_in_installments",
  "force_new_subscription",
];

const addProduct = ({
  cart,
  product,
  url,
  referrer,
}: {
  cart: CartState;
  product: ProductToAdd;
  url: URL;
  referrer: string | null;
}) => {
  const existing = findCartItem(cart, product.product.permalink, product.option_id);

  const urlParameters: Record<string, string> = {};
  for (const [key, value] of url.searchParams.entries()) if (!GUMROAD_PARAMS.includes(key)) urlParameters[key] = value;

  const option = product.product.options.find(({ id }) => id === product.option_id);
  const newItem = {
    ...product,
    quantity: Math.min(
      product.quantity || 1,
      (option ? option.quantity_left : product.product.quantity_remaining) ?? Infinity,
    ),
    url_parameters: urlParameters,
    referrer: referrer || "direct",
    recommender_model_name: url.searchParams.get("recommender_model_name"),
  };
  if (existing) Object.assign(existing, newItem);
  else cart.items.unshift(newItem);
};

export type InitialCheckout = {
  cart: CartState;
  // The buyer tried to add more than max_allowed_cart_products; the caller must
  // surface the "too many products" alert (a side effect kept out of this pure fn).
  overLimit: boolean;
  // Sellers whose third-party analytics should be initialized, once, on mount.
  sellersToTrack: { id: string; analytics: AnalyticsData }[];
  // begin_checkout events that should fire, once, on mount.
  beginCheckoutEvents: BeginCheckoutEvent[];
};

/**
 * Pure computation of the initial checkout cart and the one-time tracking
 * intentions for the checkout page.
 *
 * This function MUST stay free of side effects (no analytics calls, no alerts,
 * no DOM mutation). It is invoked from a `useRef` initializer in the checkout
 * page precisely because Inertia's `useForm` re-invokes a *function* initializer
 * on every render; any side effect placed inline there fires on every render and
 * (on the add_products arrival flow) re-emitted begin_checkout/pixel events until
 * mobile Safari crashed. See gumroad-private#658. The caller flushes the returned
 * `overLimit` / `sellersToTrack` / `beginCheckoutEvents` exactly once via useRunOnce.
 */
export const computeInitialCheckout = ({
  cart,
  clearCart,
  addProducts,
  maxAllowedCartProducts,
  url,
  documentReferrer,
}: {
  cart: CartState | null;
  clearCart: boolean;
  addProducts: ProductToAdd[];
  maxAllowedCartProducts: number;
  url: URL;
  documentReferrer: string;
}): InitialCheckout => {
  const initialCart = clearCart ? newCartState() : (cart ?? newCartState());
  const urlReferrer = url.searchParams.get("referrer");
  const referrer = urlReferrer && decodeURIComponent(urlReferrer);
  const returnUrl = referrer || documentReferrer;
  if (returnUrl) initialCart.returnUrl = returnUrl;

  const newAddProducts = addProducts.filter(
    (product) => !findCartItem(initialCart, product.product.permalink, product.option_id),
  );
  if (initialCart.items.length + newAddProducts.length > maxAllowedCartProducts) {
    initialCart.items = initialCart.items.slice(0, maxAllowedCartProducts);
    return { cart: initialCart, overLimit: true, sellersToTrack: [], beginCheckoutEvents: [] };
  }

  const sellersToTrack: { id: string; analytics: AnalyticsData }[] = [];
  const beginCheckoutEvents: BeginCheckoutEvent[] = [];

  if (addProducts.length) {
    for (const product of [...addProducts].reverse()) {
      addProduct({ cart: initialCart, product, url, referrer });
    }

    const creatorCarts = new Map<string, CartItem[]>();
    for (const item of initialCart.items) {
      sellersToTrack.push({ id: item.product.creator.id, analytics: item.product.analytics });

      creatorCarts.set(item.product.creator.id, [...(creatorCarts.get(item.product.creator.id) ?? []), item]);
    }

    for (const [creatorId, creatorCart] of creatorCarts) {
      const products = creatorCart.map((item) => ({
        permalink: item.product.permalink,
        name: item.product.name,
        quantity: item.quantity,
        price: convertToUSD(item, getDiscountedPrice(initialCart, item).price) / 100.0,
      }));
      beginCheckoutEvents.push({
        action: "begin_checkout",
        seller_id: creatorId,
        price: products.reduce((sum, { price, quantity }) => sum + price * quantity, 0),
        products,
      });
    }

    initialCart.rejectPppDiscount = false;
  }

  return { cart: initialCart, overLimit: false, sellersToTrack, beginCheckoutEvents };
};
