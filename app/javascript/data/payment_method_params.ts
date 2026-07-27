import { StripeError } from "@stripe/stripe-js";

// Client-side details about the wallet (Apple Pay / Google Pay) behind a tokenized
// PaymentMethod. The billing address feeds checkout's tax-location logic — for wallet payments
// the wallet sheet, not the checkout form, is the buyer's source of truth — and the type is
// reported to the server for analytics.
export type WalletPaymentMethodDetails = {
  type: string;
  billingAddress: {
    country: string | null;
    postal_code: string | null;
    state: string | null;
  } | null;
};

// The billing address the buyer typed into the Payment Element's own pane when the element
// collected the full billing details itself ("element-full" collection mode — UPI on digital
// carts). Checkout adopts it as the tax location, exactly like a wallet's billing address:
// checkout's own country/ZIP fields are hidden for these selections, so the pane is the buyer's
// only (and authoritative) address input.
export type ElementCollectedBillingAddress = {
  country: string | null;
  postal_code: string | null;
  state: string | null;
};

export type CardPaymentMethodParams = {
  status: "success";
  type: "card";
  reusable: false;
  stripe_payment_method_id: string;
  card_country: string | null;
  card_country_source: "stripe";
  // Present only when the buyer paid with a wallet through the Payment Element. Omitted (never
  // null) for card payments so spreading these params into server requests stays unchanged.
  wallet?: WalletPaymentMethodDetails;
  // Present only when the element collected the full billing details itself ("element-full" —
  // UPI on digital carts). Omitted otherwise, for the same spread-safety reason as `wallet`.
  elementBillingAddress?: ElementCollectedBillingAddress;
  // The full name collected alongside elementBillingAddress. Checkout's own name field is
  // hidden in element-full mode, so this value must be adopted before creating the purchase.
  elementBillingFullName?: string;
};
export type PaymentRequestPaymentMethodParams = {
  wallet_type: string;
  // Payment Request Button params never carry Payment Element wallet details; declaring the
  // key as always-undefined lets code handle the union of both param shapes type-safely.
  wallet?: undefined;
  elementBillingAddress?: undefined;
  elementBillingFullName?: undefined;
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
  // PayPal params never carry Payment Element wallet details or element-collected billing
  // details; declaring the keys as always-undefined lets serializeCardParamsIntoQueryParamsObject
  // strip them from the whole AnyPaymentMethodParams union type-safely.
  wallet?: undefined;
  elementBillingAddress?: undefined;
  elementBillingFullName?: undefined;
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
  // Same as PayPalNativePaymentMethodParams above: never present, declared for union safety.
  wallet?: undefined;
  elementBillingAddress?: undefined;
  elementBillingFullName?: undefined;
};
export type ReusablePayPalNativePaymentMethodParams = {
  status: "success";
  type: "paypal-native";
  reusable: true;
  billingToken: string;
  billing_agreement_id: string;
  visual: string;
  card_country: string;
  // Same as PayPalNativePaymentMethodParams above: never present, declared for union safety.
  wallet?: undefined;
  elementBillingAddress?: undefined;
  elementBillingFullName?: undefined;
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
  // The wallet and element-collected fields are client-side checkout context (tax location,
  // purchase name, and the wallet type reported with the purchase). The account and subscription
  // endpoints this serializer feeds have no contract for them, so strip them before sending the
  // request. The purchase path reads the values it needs explicitly.
  const {
    status: _,
    type: __,
    reusable: ___,
    wallet: ____,
    elementBillingAddress: _____,
    elementBillingFullName: ______,
    ...rest
  } = cardParams;
  return rest;
};
