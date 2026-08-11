import { ReusablePayPalNativePaymentMethodParams } from "$app/data/payment_method_params";

export type PayPalNativeResultInfo = {
  kind: "billingAgreement";
  billingToken: string;
  agreementId: string;
  email: string;
  country: string;
};

export const preparePaypalPaymentMethodData = (
  info: PayPalNativeResultInfo,
): ReusablePayPalNativePaymentMethodParams => ({
  status: "success",
  type: "paypal-native",
  reusable: true,
  billingToken: info.billingToken,
  billing_agreement_id: info.agreementId,
  visual: info.email,
  card_country: info.country,
});
