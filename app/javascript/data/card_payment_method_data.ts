import { PaymentRequestPaymentMethodEvent, StripeCardElement } from "@stripe/stripe-js";
import { cast } from "ts-safe-cast";

import {
  CardPaymentMethodParams,
  PaymentRequestPaymentMethodParams,
  ReusableCardPaymentMethodParams,
  ReusablePaymentRequestPaymentMethodParams,
  StripeErrorParams,
} from "$app/data/payment_method_params";
import { request } from "$app/utils/request";
import { getStripeInstance } from "$app/utils/stripe_loader";

import { Product } from "$app/components/Checkout/payment";

type ReusableCCVariation<CardParams extends CardPaymentMethodParams | PaymentRequestPaymentMethodParams> =
  CardParams extends CardPaymentMethodParams
    ? ReusableCardPaymentMethodParams
    : CardParams extends PaymentRequestPaymentMethodParams
      ? ReusablePaymentRequestPaymentMethodParams
      : never;

type CardData = {
  cardElement: StripeCardElement | { token: string };
  email: string;
  zipCode?: string;
};
export const prepareCardPaymentMethodData = async (
  cardData: CardData,
): Promise<CardPaymentMethodParams | StripeErrorParams> => {
  const stripe = await getStripeInstance();

  const paymentMethodResult = await stripe.createPaymentMethod({
    type: "card",
    card: cardData.cardElement,
    billing_details: { address: { postal_code: cardData.zipCode ?? "" }, email: cardData.email },
  });

  if (paymentMethodResult.error) {
    return { status: "error", stripe_error: paymentMethodResult.error };
  }
  return {
    status: "success",
    type: "card",
    reusable: false,
    stripe_payment_method_id: paymentMethodResult.paymentMethod.id,
    card_country: paymentMethodResult.paymentMethod.card?.country ?? null,
    card_country_source: "stripe",
  };
};

export const preparePaymentRequestPaymentMethodData = (
  paymentRequestEvent: PaymentRequestPaymentMethodEvent,
): PaymentRequestPaymentMethodParams => {
  const paymentMethod = paymentRequestEvent.paymentMethod;
  return {
    status: "success",
    type: "payment-request",
    reusable: false,
    stripe_payment_method_id: paymentMethod.id,
    card_country: paymentMethod.card ? paymentMethod.card.country : null,
    card_country_source: "stripe",
    email: paymentMethod.billing_details.email,
    zip_code: paymentMethod.billing_details.address ? paymentMethod.billing_details.address.postal_code : null,
    wallet_type: cast(paymentMethod.card?.wallet?.type),
  };
};

export const confirmCardIfNeeded = async <
  CardParams extends CardPaymentMethodParams | PaymentRequestPaymentMethodParams,
>(
  data: PrepareFutureChargesResponse<CardParams>,
): Promise<ReusableCCVariation<CardParams> | StripeErrorParams> => {
  const cardParams = data.cardParams;

  if (cardParams.status === "success" && data.requiresCardSetup) {
    const stripe = await getStripeInstance();
    const result = await stripe.confirmCardSetup(data.requiresCardSetup.client_secret);
    if (result.error) {
      return { status: "error", stripe_error: result.error };
    }
    return cardParams;
  }
  return cardParams;
};

type PrepareFutureChargesRequest<CardParams extends CardPaymentMethodParams | PaymentRequestPaymentMethodParams> = {
  products: Product[];
  cardParams: CardParams;
};
type PrepareFutureChargesResponse<CardParams extends CardPaymentMethodParams | PaymentRequestPaymentMethodParams> =
  | {
      cardParams: ReusableCCVariation<CardParams>;
      requiresCardSetup: false | { client_secret: string };
    }
  | {
      cardParams: StripeErrorParams;
      requiresCardSetup: false;
    };
export const prepareFutureCharges = async <
  CardParams extends CardPaymentMethodParams | PaymentRequestPaymentMethodParams,
>(
  data: PrepareFutureChargesRequest<CardParams>,
): Promise<PrepareFutureChargesResponse<CardParams>> => {
  const response = await request({
    method: "POST",
    url: Routes.stripe_setup_intents_path(),
    accept: "json",
    data: { ...data.cardParams, products: data.products },
  });

  if (response.ok) {
    const responseData = cast<CreateSetupIntentSuccessResponse>(await response.json());
    return {
      cardParams: {
        ...data.cardParams,
        stripe_customer_id: responseData.reusable_token,
        stripe_setup_intent_id: responseData.setup_intent_id,
        status: "success",
        reusable: true,
      },
      requiresCardSetup: "requires_card_setup" in responseData ? { client_secret: responseData.client_secret } : false,
    };
  }
  const responseData = cast<CreateSetupIntentErrorResponse>(await response.json());
  return {
    cardParams: {
      stripe_error: {
        type: "api_error",
        message: responseData.error_message,
        ...(responseData.error_code ? { code: responseData.error_code } : {}),
      },
      status: "error",
    },
    requiresCardSetup: false,
  };
};
type CreateSetupIntentSuccessResponse =
  | { success: true; reusable_token: string; setup_intent_id: string; requires_card_setup: true; client_secret: string }
  | { success: true; reusable_token: string; setup_intent_id: string };
type CreateSetupIntentErrorResponse = { success: false; error_message: string; error_code?: string };
