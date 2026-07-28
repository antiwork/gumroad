import * as React from "react";
import typia from "typia";

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
// So the recovery re-fetches the cart props (the rate lives there), merges the current rates
// into the cart the buyer is holding, and only then asks for a fresh quote.
//
// The caller injects its Inertia and form plumbing so this stays a plain function that can be
// exercised without mounting the checkout page.
export type BuyerCurrencyQuoteRecoveryDeps = {
  // Partially reloads the page's `cart` prop. Calls back with the server's response props on
  // success, or with nothing when the reload itself failed.
  reloadCartProps: (callbacks: { onSuccess: (props: unknown) => void; onError: () => void }) => void;
  // Reads the cart the buyer is currently holding, with their choices in it. This is a getter
  // rather than a value because the reload is asynchronous and the checkout stays editable while
  // it is in flight: the buyer can change a quantity, an option, or a pay-what-you-want price in
  // that window. Merging into a cart captured when the recovery started would write that older
  // snapshot back and quote it, silently undoing the edit they just made.
  getCart: () => CartState;
  // Persists a cart whose rates changed. Only called when a rate actually moved.
  setCart: (cart: CartState) => void;
  // Re-requests a surcharge quote for the given cart.
  requote: (cart: CartState) => void;
};

// Hands back a getter that always reads the cart from the most recent render.
//
// The recovery needs this because the function that starts it — and any plain closure over `cart`
// — belongs to one particular render, while the reload lands later, after the buyer may have
// edited the cart. The subtlety is *when* the stored value is refreshed. Synchronizing it in an
// effect leaves a window: effects are flushed on React's own schedule, and the callback that
// resolves the reload is free to run before that happens, so the getter would still be holding
// the cart from before the edit — the exact overwrite this indirection exists to prevent.
// Assigning during render closes the window, because a render always precedes the commit that
// makes the edit visible to the buyer, and therefore precedes anything they can do next.
export const useLatestCartGetter = (cart: CartState): (() => CartState) => {
  const latest = React.useRef(cart);
  // Writing a ref while rendering is normally something to avoid, since a render React throws
  // away would still leave its value behind. It is safe for this one: the value is a cart the
  // buyer's own form state already holds, the write is the same on every re-render of a given
  // cart, and nothing reads the ref during rendering.
  latest.current = cart;
  return React.useCallback(() => latest.current, []);
};

export const recoverFromInvalidBuyerCurrencyQuote = ({
  reloadCartProps,
  getCart,
  setCart,
  requote,
}: BuyerCurrencyQuoteRecoveryDeps) => {
  reloadCartProps({
    onSuccess: (props) => {
      // Validate only the prop being read, and tolerate it being missing or malformed rather
      // than throwing: a partial reload merges into the page's existing props, so asserting the
      // whole page shape here would let an unrelated prop change turn a recoverable checkout
      // into a crash. Without usable refreshed rates the recovery degrades to a plain re-quote.
      const validated = typia.validate<{ cart: CartState | null }>(props);
      const refreshed = validated.success ? validated.data.cart : null;
      const cart = getCart();
      const updated = refreshed ? withRefreshedExchangeRates(cart, refreshed) : cart;
      if (updated !== cart) setCart(updated);
      requote(updated);
    },
    // Still re-request a quote if the reload failed, so the checkout returns to a usable state
    // rather than sitting disabled. That retry can fail the same way, but it fails visibly.
    onError: () => requote(getCart()),
  });
};
