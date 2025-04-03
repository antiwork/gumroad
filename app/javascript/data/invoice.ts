import { cast } from "ts-safe-cast";

import { request, ResponseError } from "$app/utils/request";

export const sendInvoice = async ({
  id,
  email,
  full_name,
  vat_id,
  street_address,
  city,
  state,
  zip_code,
  country_code,
  additional_notes,
}: {
  id: string;
  email: string;
  full_name: string;
  vat_id: null | string;
  street_address: string;
  city: string;
  state: string;
  zip_code: string;
  country_code: string;
  additional_notes: string;
}) => {
  const response = await request({
    method: "POST",
    url: Routes.send_invoice_purchase_path(id, { email }),
    accept: "json",
    data: {
      id,
      email,
      full_name,
      vat_id,
      street_address,
      city,
      state,
      zip_code,
      country_code,
      additional_notes,
    },
  });
  if (!response.ok) throw new ResponseError();
  return cast<{ success: true; message: string; file_location: string } | { success: false; message: string }>(
    await response.json(),
  );
};
