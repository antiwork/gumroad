import { StripeCardElement, StripeError } from "@stripe/stripe-js";

import { getStripeInstance } from "$app/utils/stripe_loader";

type CardDetails = { cardElement: StripeCardElement; name?: string };

export class RefundPaymentMethodCardError extends Error {
  constructor(readonly stripeError: StripeError) {
    super();
  }
}

export const prepareRefundPaymentMethodToken = async ({ cardElement, name }: CardDetails) => {
  const stripe = await getStripeInstance();
  const tokenResult = await stripe.createToken(cardElement, name ? { name } : undefined);

  if (tokenResult.error) throw new RefundPaymentMethodCardError(tokenResult.error);

  return { stripe_token: tokenResult.token.id };
};
