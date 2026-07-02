import typia from "typia";

import type { CurrencyCode } from "$app/utils/currency";
import { request, ResponseError } from "$app/utils/request";

export type GetSurchargesRequest = {
  products: {
    permalink: string;
    quantity: number;
    price: number;
    subscription_id?: string | undefined;
  }[];
  postal_code?: string;
  country: string;
  state?: string;
  vat_id?: string;
};

export type SurchargesResponse = {
  vat_id_valid: boolean;
  has_vat_id_input: boolean;
  shipping_rate_cents: number;
  tax_cents: number;
  tax_included_cents: number;
  subtotal: number;
  buyer_currency_quote: {
    token: string;
    currency: CurrencyCode;
    canonical_total_cents: number;
    presentment_total_cents: number;
    rate: number;
    subunit_to_unit: number;
    expires_at: string;
  } | null;
};

export const getSurcharges = async (data: GetSurchargesRequest, abortSignal?: AbortSignal) => {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.customer_surcharges_path(),
    abortSignal,
    data,
  });
  if (!response.ok) throw new ResponseError();
  return typia.assert<SurchargesResponse>(await response.json());
};
