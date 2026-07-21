import typia from "typia";

import type { CurrencyCode } from "$app/utils/currency";
import { request, ResponseError } from "$app/utils/request";

export type GetSurchargesRequest = {
  products: {
    permalink: string;
    quantity: number;
    price: number;
    // The share of the buyer's tip included in `price`, so the server can carve it back out
    // when allocating the buyer-currency quote across the cart's lines and components.
    tip_cents: number;
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
    // The server-owned split of the locked presentment total across the request's product
    // lines, in request order, computed with the same largest-remainder rounding the charge
    // uses to persist purchase presentment rows. The checkout renders these amounts
    // verbatim so the visible lines always sum to the locked total and match the receipt.
    // Optional only for rolling deploy compatibility with servers that predate this field;
    // without it the browser treats the quote as unusable and stays in canonical currency.
    line_allocations?:
      | {
          permalink: string;
          price_cents: number;
          tip_cents: number;
          tax_cents: number;
          shipping_cents: number;
          total_cents: number;
        }[]
      | undefined;
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
