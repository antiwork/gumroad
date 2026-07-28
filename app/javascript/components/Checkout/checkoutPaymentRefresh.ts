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
// So instead of guessing, ask the server again. The recovery is another cart save rather than a
// bare re-request of the configuration, and that choice is the load-bearing part: a save carries
// the cart the client currently holds, so its response is the configuration for that same cart.
// A bare re-request answers for whatever the server happens to hold at that moment, which is not
// necessarily the cart the buyer is looking at — if an edit landed in between, adopting that answer
// would lift the hold onto a configuration for a cart the buyer has already changed, the exact
// mismatch the hold exists to prevent.
//
// Saves also supersede each other, which is what keeps two recoveries from fighting. The cart PATCH
// is a synchronous Inertia visit, and Inertia's sync request stream is interruptible with one slot:
// starting a newer save interrupts the in-flight one. The interrupted save's `onSuccess` never runs
// and its `onFinish` reports `interrupted`, so it neither adopts a stale configuration nor starts a
// recovery for a hold the newer save now owns.
//
// If the recovery save also comes back empty-handed the hold stays on: Pay remains disabled and the
// buyer is told to reload, the only direction that cannot charge through a mismatched element.

// The name of the prop carrying the payment configuration. A response counts as having delivered
// one only if this key is actually present in it.
const CHECKOUT_PAYMENT_PROP = "checkout_payment";

export const CHECKOUT_PAYMENT_REFRESH_FAILED_MESSAGE =
  "We couldn't refresh your payment details. Please reload the page to continue.";

type ResponseProps = { props: Record<string, unknown> };

// Inertia marks a visit cancelled (the caller aborted it) or interrupted (a newer synchronous visit
// took its slot) and passes those flags to `onFinish`, which it fires for every terminal outcome
// including those two.
type FinishedVisit = { cancelled?: boolean; interrupted?: boolean };

export type CartSaveCallbacks = {
  onSuccess: (page: ResponseProps) => void;
  onFinish: (visit?: FinishedVisit) => void;
};

export const deliveredCheckoutPayment = (page: ResponseProps) => CHECKOUT_PAYMENT_PROP in page.props;

/**
 * Builds the callbacks for a cart save so that a save which does not deliver a payment
 * configuration recovers by saving again.
 *
 * `save` re-issues the cart PATCH with a fresh set of these callbacks, and `onUnrecoverable`
 * reports that the hold could not be lifted — the buyer has to reload the page. `recoveriesLeft`
 * bounds the chain so an outage cannot retry forever; it is an internal detail of the chain rather
 * than something callers are expected to pass.
 */
export const buildCartSaveRefreshCallbacks = ({
  save,
  onUnrecoverable,
  recoveriesLeft = 1,
}: {
  save: (callbacks: CartSaveCallbacks) => void;
  onUnrecoverable: (message: string) => void;
  recoveriesLeft?: number;
}): CartSaveCallbacks => {
  // Read off the response rather than inferred from which callback fired: Inertia calls onError
  // only for a valid Inertia response carrying a props.errors payload, so "onError did not run"
  // does not mean a configuration arrived.
  let delivered = false;

  return {
    onSuccess: (page) => {
      delivered = deliveredCheckoutPayment(page);
    },
    onFinish: (visit) => {
      if (delivered) return;

      // A newer save took this one's place. It carries the buyer's latest cart and its response is
      // what will lift the hold, so this save must not recover on its behalf — doing so would race
      // two saves and let the older one's answer be adopted for the newer one's cart.
      if (visit?.cancelled === true || visit?.interrupted === true) return;

      if (recoveriesLeft <= 0) {
        // Fail closed. The hold is left in place and the buyer is told the only thing that can fix
        // it, rather than being handed a Pay button we cannot vouch for.
        onUnrecoverable(CHECKOUT_PAYMENT_REFRESH_FAILED_MESSAGE);
        return;
      }

      save(buildCartSaveRefreshCallbacks({ save, onUnrecoverable, recoveriesLeft: recoveriesLeft - 1 }));
    },
  };
};
