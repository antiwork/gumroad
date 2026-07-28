// Recovering the checkout's payment configuration when the cart save that was supposed to bring it
// back does not deliver one.
//
// Background: the payment configuration (which Stripe element is mounted, in which currency) is
// computed by the server from the cart, so a cart edit puts a hold on Pay until the recomputed
// configuration arrives with the save's response. If the save finishes without delivering one — a
// dropped connection, a timeout, a 500 rendering an HTML error page, a validation error — something
// has to decide what happens to that hold.
//
// Releasing it would be wrong. A failed request does not tell us whether the cart was persisted:
// the write may have committed and only its response been lost, in which case the server now holds
// the edited cart while the configuration on screen was computed for the previous one. Re-enabling
// Pay there could charge the buyer through an element mounted in the wrong currency for the cart
// the order is actually built from.
//
// So instead of guessing, ask the server again for just the configuration. Its answer is computed
// from the persisted cart whichever way the lost write went, which makes it authoritative. When it
// arrives the reducer adopts it and the hold lifts on its own. If that retry also fails the hold
// stays on: Pay remains disabled and the buyer is told to reload, the only direction that cannot
// charge through a mismatched element.

// The name of the prop carrying the payment configuration. A response counts as having delivered
// one only if this key is actually present in it.
const CHECKOUT_PAYMENT_PROP = "checkout_payment";

export const CHECKOUT_PAYMENT_REFRESH_FAILED_MESSAGE =
  "We couldn't refresh your payment details. Please reload the page to continue.";

type ResponseProps = { props: Record<string, unknown> };

type RequestCallbacks = {
  onSuccess: (page: ResponseProps) => void;
  onFinish: () => void;
};

// Only the pieces of Inertia's visit options this module sets, so the callers' tests do not have to
// stand up a router.
type ReloadOptions = RequestCallbacks & { only: string[] };

export const deliveredCheckoutPayment = (page: ResponseProps) => CHECKOUT_PAYMENT_PROP in page.props;

/**
 * Builds the callbacks for the debounced cart save. `reload` re-requests just the payment
 * configuration (Inertia's `router.reload`), and `onUnrecoverable` reports that the hold could not
 * be lifted — the buyer has to reload the page.
 */
export const buildCartSaveRefreshCallbacks = ({
  reload,
  onUnrecoverable,
}: {
  reload: (options: ReloadOptions) => void;
  onUnrecoverable: (message: string) => void;
}): RequestCallbacks => {
  // Read off the response rather than inferred from which callback fired: Inertia calls onError
  // only for a valid Inertia response carrying a props.errors payload, so "onError did not run"
  // does not mean a configuration arrived.
  let delivered = false;

  const retry = () => {
    let retryDelivered = false;
    reload({
      only: [CHECKOUT_PAYMENT_PROP],
      onSuccess: (page) => {
        retryDelivered = deliveredCheckoutPayment(page);
      },
      onFinish: () => {
        // Fail closed. The hold is left in place and the buyer is told the only thing that can fix
        // it, rather than being handed a Pay button we cannot vouch for.
        if (!retryDelivered) onUnrecoverable(CHECKOUT_PAYMENT_REFRESH_FAILED_MESSAGE);
      },
    });
  };

  return {
    onSuccess: (page) => {
      delivered = deliveredCheckoutPayment(page);
    },
    // onFinish runs for every terminal outcome. Inertia skips it for requests cancelled or
    // superseded by a newer visit, so a save overtaken by the buyer's next edit does not start a
    // recovery for a hold that edit has already re-taken.
    onFinish: () => {
      if (!delivered) retry();
    },
  };
};
