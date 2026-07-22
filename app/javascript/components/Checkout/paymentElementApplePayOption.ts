import { StripePaymentElementOptions } from "@stripe/stripe-js";

import { getApplePayRecurringPaymentRequest } from "$app/components/Checkout/applePayRecurringPaymentRequest";
import { Product } from "$app/components/Checkout/payment";

// Stripe's types define ApplePayOption in an internal module that isn't re-exported from the
// package root, so derive it from the exported Payment Element options shape (the same trick
// applePayRecurringPaymentRequest.ts uses for the declaration itself).
export type PaymentElementApplePayOption = NonNullable<StripePaymentElementOptions["applePay"]>;

// Assembles the `applePay` option for the Payment Element from cart state, or undefined when the
// option should not be set at all.
//
// This is the Payment Element counterpart of the Payment Request Button's recurring declaration
// in PaymentForm.tsx: both surfaces feed the same cart through the same shared builder
// (getApplePayRecurringPaymentRequest), so for a given cart they describe the identical recurring
// agreement on the Apple Pay sheet and Apple mints the same kind of token — a device-independent
// merchant token (MPAN) — either way. The builder owns the cart-shape policy (exactly one
// recurring item; trialBilling for free trials; an end date for fixed-duration plans); this
// function only owns the rollout gating and the option's Payment-Element-specific shape.
//
// Two independent per-seller flags gate the declaration:
// - request_apple_pay_merchant_tokens: the MPAN rollout itself. Off means the Apple Pay sheet
//   stays a plain one-time request (a device token), exactly like before the rollout.
// - payment_element_wallets: whether the Payment Element renders Apple Pay at all
//   (antiwork/gumroad#5768). Off means the element is a pure card form and the separate Payment
//   Request Button carries the wallet (and its own declaration), so setting the option here would
//   be dead config at best. Keeping the gate here keeps the two rollouts independently
//   controllable.
//
// When either flag is off we return undefined so the element's options are byte-identical to
// today's. When both are on we ALWAYS return an object — with an explicit null declaration for
// carts that don't qualify — because react-stripe-js forwards option changes to the mounted
// element via element.update(): an explicit null clears a previously-declared agreement when cart
// edits make the cart stop qualifying, whereas omitting the key would leave the stale declaration
// on the sheet.
export const getPaymentElementApplePayOption = ({
  products,
  managementURL,
  requestApplePayMerchantTokens,
  paymentElementWallets,
}: {
  products: Product[];
  managementURL: string;
  requestApplePayMerchantTokens: boolean;
  paymentElementWallets: boolean;
}): PaymentElementApplePayOption | undefined => {
  if (!requestApplePayMerchantTokens || !paymentElementWallets) return undefined;
  const recurringPaymentRequest = getApplePayRecurringPaymentRequest(products, managementURL);
  return recurringPaymentRequest ? { recurringPaymentRequest } : { recurringPaymentRequest: null };
};
