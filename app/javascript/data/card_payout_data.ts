import { StripeCardElement, StripeError } from "@stripe/stripe-js";

import { getStripeInstance } from "$app/utils/stripe_loader";

const PAYOUT_CURRENCY = "usd";

type CardDetails = { cardElement: StripeCardElement; zipCode?: string };

export type CardPayoutToken = { stripe_token: string; card_country: string | null; card_country_source: "stripe" };
export class CardPayoutError extends Error {
  constructor(readonly stripeError: StripeError) {
    super();
  }
}

export const prepareCardTokenForPayouts = async (cardDetails: CardDetails): Promise<CardPayoutToken> => {
  const stripe = await getStripeInstance();

  const tokenResult = await stripe.createToken(cardDetails.cardElement, {
    address_zip: cardDetails.zipCode || "",
    currency: PAYOUT_CURRENCY, // Set so that we can use the card for payouts.
  });

  if (tokenResult.error) throw new CardPayoutError(tokenResult.error);

  return {
    stripe_token: tokenResult.token.id,
    card_country: tokenResult.token.card?.country ?? null,
    card_country_source: "stripe",
  };
};
