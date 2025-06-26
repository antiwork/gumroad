import { StripeError } from "@stripe/stripe-js";

export type CardPaymentMethodParams = {
  status: "success";
  type: "card";
  reusable: false;
  stripe_payment_method_id: string;
  card_country: string | null;
  card_country_source: "stripe";
};
export type PaymentRequestPaymentMethodParams = {
  wallet_type: string;
  status: "success";
  type: "payment-request";
  reusable: false;
  stripe_payment_method_id: string;
  card_country: string | null;
  card_country_source: "stripe";
  email: string | null;
  zip_code: string | null;
};
export type PayPalNativePaymentMethodParams = {
  status: "success";
  type: "paypal-native";
  reusable: false;
  paypal_order_id: string;
  visual: string;
  card_country: string;
};

export type ReusableCardPaymentMethodParams = { stripe_customer_id: string; stripe_setup_intent_id: string } & Omit<
  CardPaymentMethodParams,
  "reusable"
> & {
    reusable: true;
  };
export type ReusablePaymentRequestPaymentMethodParams = {
  stripe_customer_id: string;
  stripe_setup_intent_id: string;
} & Omit<PaymentRequestPaymentMethodParams, "reusable"> & {
    reusable: true;
  };
export type ReusablePayPalBraintreePaymentMethodParams = {
  status: "success";
  type: "paypal-braintree";
  reusable: true;
  braintree_transient_customer_store_key: string | null;
  braintree_device_data: string | null;
};
export type ReusablePayPalNativePaymentMethodParams = {
  status: "success";
  type: "paypal-native";
  reusable: true;
  billingToken: string;
  billing_agreement_id: string;
  visual: string;
  card_country: string;
};

export type AnyPayPalMethodParams =
  | ReusablePayPalBraintreePaymentMethodParams
  | ReusablePayPalNativePaymentMethodParams
  | PayPalNativePaymentMethodParams;

export type StripeErrorParams = { status: "error"; stripe_error: StripeError };

export type AnyPaymentMethodParams =
  | CardPaymentMethodParams
  | ReusableCardPaymentMethodParams
  | PaymentRequestPaymentMethodParams
  | ReusablePaymentRequestPaymentMethodParams
  | AnyPayPalMethodParams;

export const isPayPalNativeParams = (
  cardParams: AnyPaymentMethodParams | StripeErrorParams,
): cardParams is PayPalNativePaymentMethodParams | ReusablePayPalNativePaymentMethodParams =>
  cardParams.status === "success" && cardParams.type === "paypal-native";

export const isPayPalBraintreeParams = (
  cardParams: AnyPaymentMethodParams | StripeErrorParams,
): cardParams is ReusablePayPalBraintreePaymentMethodParams =>
  cardParams.status === "success" && cardParams.type === "paypal-braintree";

export const isPayPalParams = (
  cardParams: AnyPaymentMethodParams | StripeErrorParams,
): cardParams is AnyPayPalMethodParams => isPayPalNativeParams(cardParams) || isPayPalNativeParams(cardParams);

// We should be able to change `AnyPaymentMethodParams` representation on the frontend without making any backend changes
// Since `AnyPaymentMethodParams` is being used to construct query params for the request to save the payment method,
// we'd have more flexibility with a function to convert a local `AnyPaymentMethodParams` type into the shape the backend expects.
// This SHOULD be updated with the mapping logic upon any significant changes to `AnyPaymentMethodParams`
export const serializeCardParamsIntoQueryParamsObject = (
  cardParams: AnyPaymentMethodParams | StripeErrorParams,
): Record<string, unknown> => {
  if (cardParams.status === "error") {
    const { status: _, ...rest } = cardParams;
    return rest;
  }
  const { status: _, type: __, reusable: ___, ...rest } = cardParams;
  return rest;
};
