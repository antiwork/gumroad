import { cast } from "ts-safe-cast";

import { CurrencyCode } from "$app/utils/currency";
import { request } from "$app/utils/request";

type BillingAgreement = {
  id: string;
  payer: {
    payer_info: {
      email: string;
      payer_id: string;
      billing_address: { country_code: string; postal_code?: string };
      first_name?: string;
      last_name?: string;
    };
  };
  shipping_address?: {
    city?: string;
    country_code: string;
    line1: string;
    line2?: string;
    postal_code?: string;
    recipient_name?: string;
    state?: string;
  };
};

export const createBillingAgreement = async (billingAgreementTokenId: string): Promise<BillingAgreement> => {
  try {
    const response = await request({
      method: "POST",
      url: Routes.billing_agreement_paypal_path(),
      accept: "json",
      data: { billing_agreement_token_id: billingAgreementTokenId },
    });

    if (response.ok) {
      return cast<BillingAgreement>(await response.json());
    }
    throw new Error("Server returned error response.");
  } catch (e) {
    // eslint-disable-next-line no-console
    console.error("Error creating a PayPal billing agreement", e);
    throw e;
  }
};

export type LineItemInfoForNativePayPalCheckout = {
  external_id: string;
  permalink: string;
  quantity: number;
  currency_code: CurrencyCode;
  total_cents: number;
  price_cents: number;
  shipping_cents: number;
  tax_cents: number;
  exclusive_tax_cents: number;
  vat_cents: number;
  exclusive_vat_cents: number;
  tax_country: string | null;
  was_recommended: boolean;
};

export const createBillingAgreementToken = async (data: { shipping: boolean }): Promise<string> => {
  try {
    const response = await request({
      url: Routes.billing_agreement_token_paypal_path(data),
      method: "POST",
      accept: "json",
    });
    const responseData = cast<{ billing_agreement_token_id: string }>(await response.json());
    return responseData.billing_agreement_token_id;
  } catch (e) {
    // eslint-disable-next-line no-console
    console.error("Error creating a PayPal billing agreement token", e);
    throw e;
  }
};
