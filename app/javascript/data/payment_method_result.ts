import { StripeCardElement } from "@stripe/stripe-js";

import { prepareBraintreePaymentMethodData } from "$app/data/braintree_payment_method_data";
import {
  confirmCardIfNeeded,
  prepareCardPaymentMethodData,
  prepareFutureCharges,
} from "$app/data/card_payment_method_data";
import {
  AnyPayPalMethodParams,
  CardPaymentMethodParams,
  PaymentRequestPaymentMethodParams,
  ReusableCardPaymentMethodParams,
  ReusablePaymentRequestPaymentMethodParams,
  StripeErrorParams,
} from "$app/data/payment_method_params";
import { PayPalNativeResultInfo, preparePaypalPaymentMethodData } from "$app/data/paypal_payment_method_data";

import { Product } from "$app/components/Checkout/payment";

// Whereas PaymentMethodParams represents the payment method itself,
// PaymentMethodResult combines PaymentMethodParams with some extra attributes, keep on file, and zip code input values, that are only relevant for specific payment methods
// Normally derived from CreditCardForm's SelectedPaymentMethod

export type SavedSelectedPaymentMethod = { type: "saved" };
export type NewCardSelectedPaymentMethod = {
  type: "card";
  element: StripeCardElement;
  email: string;
  keepOnFile: null | boolean;
  zipCode: null | string;
};
export type NewPayPalBraintreeSelectedPaymentMethod = {
  type: "paypal-braintree";
  nonce: string;
  deviceData: null | string;
  keepOnFile: null | boolean;
};
export type NewPayPalNativeSelectedPaymentMethod = {
  type: "paypal-native";
  info: PayPalNativeResultInfo;
  keepOnFile: null;
};
export type SelectedPaymentMethod =
  | SavedSelectedPaymentMethod
  | NewCardSelectedPaymentMethod
  | NewPayPalBraintreeSelectedPaymentMethod
  | NewPayPalNativeSelectedPaymentMethod;
type SavedPaymentMethodResult = { type: "saved" };
type OneOffNewCardPaymentMethodResult = {
  type: "new";
  cardParamsResult:
    | {
        type: "cc";
        cardParams: CardPaymentMethodParams;
        keepOnFile: null | boolean;
        zipCode: null | string;
      }
    | { type: "error"; cardParams: StripeErrorParams };
};
type ReusableNewCardPaymentMethodResult = {
  type: "new";
  cardParamsResult:
    | {
        type: "cc";
        cardParams: ReusableCardPaymentMethodParams;
        keepOnFile: null | boolean;
        zipCode: null | string;
      }
    | { type: "paypal"; cardParams: AnyPayPalMethodParams; keepOnFile: null | boolean }
    | { type: "error"; cardParams: StripeErrorParams };
};
type PayPalPaymentMethodResult = {
  type: "new";
  cardParamsResult: { type: "paypal"; cardParams: AnyPayPalMethodParams; keepOnFile: null | boolean };
};
type OneOffPaymentRequestPaymentMethodResult = {
  type: "new";
  cardParamsResult:
    | {
        type: "cc-payment-request";
        cardParams: PaymentRequestPaymentMethodParams;
      }
    | { type: "error"; cardParams: StripeErrorParams };
};
type ReusablePaymentRequestPaymentMethodResult = {
  type: "new";
  cardParamsResult:
    | {
        type: "cc-payment-request";
        cardParams: ReusablePaymentRequestPaymentMethodParams;
      }
    | { type: "error"; cardParams: StripeErrorParams };
};

export type AnyPaymentMethodResult =
  | SavedPaymentMethodResult
  | PayPalPaymentMethodResult
  | OneOffNewCardPaymentMethodResult
  | ReusableNewCardPaymentMethodResult
  | OneOffPaymentRequestPaymentMethodResult
  | ReusablePaymentRequestPaymentMethodResult;

// FIXME: overloads will not properly type the cases where an argument is a union
// see https://github.com/microsoft/TypeScript/issues/33912
// this fn & the other one should be changed to properly type these cases when TypeScript is able to properly support this in some form
// or when we come up with a good work around
export async function getPaymentMethodResult(selected: SavedSelectedPaymentMethod): Promise<SavedPaymentMethodResult>;
export async function getPaymentMethodResult(
  selected: NewPayPalNativeSelectedPaymentMethod | NewPayPalBraintreeSelectedPaymentMethod,
): Promise<PayPalPaymentMethodResult>;
export async function getPaymentMethodResult(
  selected: NewCardSelectedPaymentMethod,
): Promise<OneOffNewCardPaymentMethodResult>;
// catch-all
export async function getPaymentMethodResult(
  selected: SelectedPaymentMethod,
): Promise<SavedPaymentMethodResult | PayPalPaymentMethodResult | OneOffNewCardPaymentMethodResult>;

export async function getPaymentMethodResult(
  selected: SelectedPaymentMethod,
): Promise<SavedPaymentMethodResult | PayPalPaymentMethodResult | OneOffNewCardPaymentMethodResult> {
  switch (selected.type) {
    case "saved": {
      return { type: "saved" };
    }
    case "paypal-braintree": {
      const cardParams = await prepareBraintreePaymentMethodData({
        braintreeNonce: selected.nonce,
        deviceData: selected.deviceData,
      });
      return {
        type: "new",
        cardParamsResult: {
          type: "paypal",
          cardParams,
          keepOnFile: selected.keepOnFile,
        },
      };
    }
    case "paypal-native": {
      if (selected.info.kind === "oneTime") {
        return {
          type: "new",
          cardParamsResult: {
            type: "paypal",
            cardParams: preparePaypalPaymentMethodData(selected.info),
            keepOnFile: selected.keepOnFile,
          },
        };
      }
      return {
        type: "new",
        cardParamsResult: {
          type: "paypal",
          cardParams: preparePaypalPaymentMethodData(selected.info),
          keepOnFile: selected.keepOnFile,
        },
      };
    }
    case "card": {
      const paymentMethodData = await prepareCardPaymentMethodData({
        cardElement: selected.element,
        email: selected.email,
      });
      if (paymentMethodData.status === "success") {
        return {
          type: "new",
          cardParamsResult: {
            type: "cc",
            cardParams: paymentMethodData,
            keepOnFile: selected.keepOnFile,
            zipCode: selected.zipCode,
          },
        };
      }
      return {
        type: "new",
        cardParamsResult: {
          type: "error",
          cardParams: paymentMethodData,
        },
      };
    }
  }
}

// FIXME: see above
type ReusableOptions = { products: Product[] };
export async function getReusablePaymentMethodResult(
  selected: SavedSelectedPaymentMethod,
  options: ReusableOptions,
): Promise<SavedPaymentMethodResult>;
export async function getReusablePaymentMethodResult(
  selected: NewPayPalNativeSelectedPaymentMethod | NewPayPalBraintreeSelectedPaymentMethod,
  options: ReusableOptions,
): Promise<PayPalPaymentMethodResult>;
export async function getReusablePaymentMethodResult(
  selected: NewCardSelectedPaymentMethod,
  options: ReusableOptions,
): Promise<ReusableNewCardPaymentMethodResult>;
// catch-all
export async function getReusablePaymentMethodResult(
  selected: SelectedPaymentMethod,
  { products }: ReusableOptions,
): Promise<SavedPaymentMethodResult | PayPalPaymentMethodResult | ReusableNewCardPaymentMethodResult>;

export async function getReusablePaymentMethodResult(
  selected: SelectedPaymentMethod,
  { products }: ReusableOptions,
): Promise<SavedPaymentMethodResult | PayPalPaymentMethodResult | ReusableNewCardPaymentMethodResult> {
  const data = await getPaymentMethodResult(selected);

  switch (data.type) {
    case "saved": {
      return { type: "saved" };
    }
    case "new": {
      if (data.cardParamsResult.type === "error") {
        // We failed to create a payment method, no need to prepare future charges.
        return { type: "new", cardParamsResult: data.cardParamsResult };
      } else if (data.cardParamsResult.type === "paypal") {
        // PayPal token should already be reusable by now
        return { type: "new", cardParamsResult: data.cardParamsResult };
      }
      const { cardParamsResult } = data;
      const cardParams = await prepareFutureCharges({
        products,
        cardParams: data.cardParamsResult.cardParams,
      }).then(confirmCardIfNeeded);
      if (cardParams.status === "success") {
        return {
          type: "new",
          cardParamsResult: {
            type: "cc",
            cardParams,
            keepOnFile: cardParamsResult.keepOnFile,
            zipCode: cardParamsResult.zipCode,
          },
        };
      }
      return { type: "new", cardParamsResult: { type: "error", cardParams } };
    }
  }
}

export const getPaymentRequestPaymentMethodResult = (
  paymentRequestParams: PaymentRequestPaymentMethodParams,
): OneOffPaymentRequestPaymentMethodResult => ({
  type: "new",
  cardParamsResult: {
    type: "cc-payment-request",
    cardParams: paymentRequestParams,
  },
});

export const getReusablePaymentRequestPaymentMethodResult = async (
  paymentRequestParams: PaymentRequestPaymentMethodParams,
  { products }: { products: Product[] },
): Promise<ReusablePaymentRequestPaymentMethodResult> => {
  const cardParams = await prepareFutureCharges({
    products,
    cardParams: paymentRequestParams,
  }).then(confirmCardIfNeeded);

  if (cardParams.status === "success") {
    return {
      type: "new",
      cardParamsResult: {
        type: "cc-payment-request",
        cardParams,
      },
    };
  }
  return { type: "new", cardParamsResult: { type: "error", cardParams } };
};
