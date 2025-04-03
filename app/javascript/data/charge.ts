import { cast } from "ts-safe-cast";

import { request, ResponseError } from "$app/utils/request";

export const lookupCharges = async (data: { email: string; last4: string | null }) => {
  const response = await request({
    method: "GET",
    accept: "json",
    url: Routes.charge_data_path({ email: data.email, last_4: data.last4, format: "json" }),
  });
  if (response.ok) return cast<{ success: boolean }>(await response.json());
  throw new ResponseError();
};

export const lookupPaypalCharges = async (data: { invoiceId: string }) => {
  const response = await request({
    method: "GET",
    accept: "json",
    url: Routes.paypal_charge_data_path({ invoice_id: data.invoiceId, format: "json" }),
  });
  if (response.ok) return cast<{ success: boolean }>(await response.json());
  throw new ResponseError();
};
