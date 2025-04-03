import { cast } from "ts-safe-cast";

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
  return cast<SurchargesResponse>(await response.json());
};
