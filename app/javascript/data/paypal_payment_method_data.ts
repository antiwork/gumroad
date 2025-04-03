import {
  PayPalNativePaymentMethodParams,
  ReusablePayPalNativePaymentMethodParams,
} from "$app/data/payment_method_params";

export type PayPalNativeResultInfo =
  | {
      kind: "billingAgreement";
      billingToken: string;
      agreementId: string;
      email: string;
      country: string;
    }
  | { kind: "oneTime"; orderId: string; email: string; country: string };

export const preparePaypalPaymentMethodData = (
  info: PayPalNativeResultInfo,
): PayPalNativePaymentMethodParams | ReusablePayPalNativePaymentMethodParams => {
  if (info.kind === "oneTime") {
    return {
      status: "success",
      type: "paypal-native",
      reusable: false,
      paypal_order_id: info.orderId,
      visual: info.email,
      card_country: info.country,
    };
  }
  return {
    status: "success",
    type: "paypal-native",
    reusable: true,
    billingToken: info.billingToken,
    billing_agreement_id: info.agreementId,
    visual: info.email,
    card_country: info.country,
  };
};
