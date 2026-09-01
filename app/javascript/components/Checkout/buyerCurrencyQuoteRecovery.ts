import * as React from "react";

import { type CartPurchaseResult, type OfferCodes } from "$app/data/purchase";

import { type CartState, withRefreshedExchangeRates } from "$app/components/Checkout/cartState";

// What the checkout has to do when the server refuses the local-currency quote at charge time.
//
// The quote binds a total the browser computed from the exchange rate that was baked into the
// page props when the page rendered, and the server refreshes stored rates every hour. A
// checkout left open across that refresh therefore recomputes a different total at charge time,
// and the quote is rejected. Re-requesting a quote from the cart already in memory would mint
// the same rejected total again — the buyer would retry forever with nothing telling them that
// only a manual page refresh can help.
//
// So the recovery needs the server's *current* rate. It reads it out of the refusal response
// itself, which already carries a freshly built product for every failed line
// (`Order::ResponseHelpers#error_response` sets `updated_product`, and CheckoutPresenter puts
// today's `exchange_rate` on it), then merges those rates into the cart the buyer is holding and
// asks for a fresh quote.
//
// Reading the rate from the response rather than re-fetching the cart is what makes this work at
// all. Creating the order persists a `failed` purchase and attaches it to the order, so
// `Order::CreateService` sees `order.persisted?` and soft-deletes the buyer's cart before
// responding. A partial reload of the `cart` prop after that point returns `cart: null` — there
// is no cart left to read a rate from — so a reload-based recovery silently degraded to
// re-quoting on the stale rate, which is exactly the behaviour it was meant to fix.
//
// The caller injects its form plumbing so this stays a plain function that can be exercised
// without mounting the checkout page.
export type BuyerCurrencyQuoteRecoveryDeps = {
  // Reads the cart the buyer is currently holding, with their choices in it. This is a getter
  // rather than a value because the caller starts the recovery from one particular render while
  // the buyer may edit the cart before it completes; see useLatestCartGetter.
  getCart: () => CartState;
  // Persists a cart whose rates changed. Only called when a rate actually moved.
  setCart: (cart: CartState) => void;
  // Re-requests a surcharge quote for the given cart.
  requote: (cart: CartState) => void;
};

// Hands back a getter that always reads the cart from the most recent render.
//
// The recovery needs this because the function that starts it — and any plain closure over `cart`
// — belongs to one particular render, while the buyer may edit the cart before the recovery runs
// its merge. The subtlety is *when* the stored value is refreshed. Synchronizing it in an effect
// leaves a window: effects are flushed on React's own schedule, so the getter could still be
// holding the cart from before the edit — the exact overwrite this indirection exists to
// prevent. Assigning during render closes the window, because a render always precedes the
// commit that makes the edit visible to the buyer, and therefore precedes anything they can do
// next.
export const useLatestCartGetter = (cart: CartState): (() => CartState) => {
  const latest = React.useRef(cart);
  // Writing a ref while rendering is normally something to avoid, since a render React throws
  // away would still leave its value behind. It is safe for this one: the value is a cart the
  // buyer's own form state already holds, the write is the same on every re-render of a given
  // cart, and nothing reads the ref during rendering.
  //
  // That safety depends on this page rendering synchronously, where a render that starts also
  // commits. If a cart edit is ever moved into startTransition, or a Suspense boundary is added
  // around the cart rows, React can abandon a render after this assignment and the ref would
  // hold a cart the buyer never saw committed.
  latest.current = cart;
  return React.useCallback(() => latest.current, []);
};

// Collects the server's current exchange rate per product out of the refused line items.
//
// Keyed by permalink because that is what the cart merges on, and because a cart can hold two
// lines of the same product (different options) whose rate is necessarily the same. Anything
// without a usable rate is left out entirely rather than defaulted: adopting a 0, a negative, or
// a non-finite rate would make convertToUSD produce Infinity/NaN and break price conversion for
// the rest of the checkout, which is worse than re-quoting on the rate the cart already has.
export const refreshedRatesFromLineItems = (lineItems: CartPurchaseResult["lineItems"]): Map<string, number> => {
  const rates = new Map<string, number>();
  for (const result of Object.values(lineItems)) {
    if (result.success) continue;
    const product = result.updated_product?.product;
    if (!product) continue;
    const rate = product.exchange_rate;
    if (typeof rate !== "number" || !Number.isFinite(rate) || rate <= 0) continue;
    rates.set(product.permalink, rate);
  }
  return rates;
};

// The amount refusal can mean an offer changed after surcharge calculation. Refreshing the cart's
// offers before requoting prevents the browser from immediately remounting the same stale amount.
//
// An empty list is not "the buyer's discounts are gone": a quote/amount refusal carries no
// replacement offers at all, so adopting it would requote the cart at full price.
export const withRefreshedOfferCodes = (cart: CartState, offerCodes: OfferCodes): CartState =>
  offerCodes.length === 0
    ? cart
    : {
        ...cart,
        discountCodes: offerCodes.map((offerCode) => ({
          ...offerCode,
          fromUrl: cart.discountCodes.find(({ code }) => code === offerCode.code)?.fromUrl ?? false,
        })),
      };

export const recoverFromInvalidBuyerCurrencyQuote = ({
  lineItems,
  getCart,
  setCart,
  requote,
}: BuyerCurrencyQuoteRecoveryDeps & { lineItems: CartPurchaseResult["lineItems"] }) => {
  const cart = getCart();
  const rates = refreshedRatesFromLineItems(lineItems);
  const updated = withRefreshedExchangeRates(cart, rates);
  // Persist only when a rate actually moved, so a refusal that had nothing to do with rates
  // doesn't cost a pointless cart save. Either way the checkout re-quotes, so the buyer is never
  // left looking at a disabled Pay button.
  if (updated !== cart) setCart(updated);
  requote(updated);
};

// Builds the recovery's plumbing from the checkout page's own pieces.
//
// This exists as its own function purely so the wiring can be tested. The bug this whole module
// fixes was a single line in the refusal branch that re-quoted straight from the in-memory cart,
// and every unit test here exercises the helpers rather than the call site — so putting that line
// back would leave the suite green while restoring the loop. Two things have to hold and are
// asserted against this factory: `requote` must convert the cart it is HANDED (the merged one),
// not re-read the page's cart, and `setCart` must write through the caller's form.
//
// Generic over what getProducts returns so the caller's own type flows through to
// dispatchUpdateProducts without an assertion.
export const buildBuyerCurrencyQuoteRecoveryDeps = <Products>({
  getLatestCart,
  setCart,
  getProducts,
  dispatchUpdateProducts,
}: {
  getLatestCart: () => CartState;
  setCart: (cart: CartState) => void;
  getProducts: (cart: CartState) => Products;
  dispatchUpdateProducts: (products: Products) => void;
}): BuyerCurrencyQuoteRecoveryDeps => ({
  getCart: getLatestCart,
  setCart,
  requote: (cart) => dispatchUpdateProducts(getProducts(cart)),
});
