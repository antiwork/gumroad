import { getStripePaymentElementAmount, State } from "$app/components/Checkout/payment";

// A wallet payment (Apple Pay / Google Pay) tokenized through the Payment Element, held back
// from submission because applying the wallet sheet's billing address changed checkout's tax
// location. The new location invalidates the surcharges quote, so the server may now calculate
// a different tax-inclusive total than the one the wallet sheet showed the buyer.
// `approvedAmount` is the Payment Element amount at the moment the buyer approved the sheet —
// the number the buyer actually agreed to pay.
export type HeldWalletPayment<PaymentMethod> = {
  paymentMethod: PaymentMethod;
  approvedAmount: number | null;
};

export type HeldWalletPaymentResolution<PaymentMethod> =
  // Surcharges are still reloading for the new tax location — keep holding.
  | { type: "wait" }
  // The recalculated total matches what the wallet sheet showed — safe to submit the held payment.
  | { type: "continue"; paymentMethod: PaymentMethod }
  // The recalculated total differs from (or could not be verified against) the approved one.
  // The buyer must re-confirm on the wallet sheet, which will now show the updated total —
  // charging a total the buyer never saw is not an option.
  | { type: "re-confirm" }
  // The submission was cancelled or failed elsewhere while holding — drop the held payment.
  | { type: "abort" };

// Decides what to do with a held wallet payment as checkout state settles. Pure so the
// wait/continue/re-confirm lifecycle can be unit-tested without rendering the checkout;
// PaymentForm.tsx re-runs this from an effect whenever surcharges or the submission status change.
export const resolveHeldWalletPayment = <PaymentMethod>(
  state: State,
  held: HeldWalletPayment<PaymentMethod>,
): HeldWalletPaymentResolution<PaymentMethod> => {
  if (state.status.type !== "starting") return { type: "abort" };
  if (state.surcharges.type === "pending" || state.surcharges.type === "loading") return { type: "wait" };
  // Surcharges failed to reload: the recalculated total is unknowable, so the approved and
  // submitted totals can't be shown to agree — treat it like a mismatch and re-confirm.
  if (state.surcharges.type === "error") return { type: "re-confirm" };
  const amount = getStripePaymentElementAmount(state);
  return amount === held.approvedAmount
    ? { type: "continue", paymentMethod: held.paymentMethod }
    : { type: "re-confirm" };
};
