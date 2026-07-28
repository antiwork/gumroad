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
  // The cart the buyer is currently holding, with their choices in it.
  cart: CartState;
  // Persists a cart whose rates changed. Only called when a rate actually moved.
  setCart: (cart: CartState) => void;
  // Re-requests a surcharge quote for the given cart.
  requote: (cart: CartState) => void;
};

export const recoverFromInvalidBuyerCurrencyQuote = ({
  reloadCartProps,
  cart,
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
      const updated = refreshed ? withRefreshedExchangeRates(cart, refreshed) : cart;
      if (updated !== cart) setCart(updated);
      requote(updated);
    },
    // Still re-request a quote if the reload failed, so the checkout returns to a usable state
    // rather than sitting disabled. That retry can fail the same way, but it fails visibly.
    onError: () => requote(cart),
  });
};
