import { cast } from "ts-safe-cast";

import { ResponseError, request } from "$app/utils/request";

export type OtherRefundPolicy = {
  id: string;
  product_name: string;
  max_refund_period_in_days: number;
  title: string;
  fine_print: string | null;
};

export const fetchOtherRefundPolicies = async (productUniquePermalink: string) =>
  request({
    method: "GET",
    accept: "json",
    url: Routes.product_other_refund_policies_path(productUniquePermalink, "json"),
  })
    .then((response) => {
      if (!response.ok) throw new ResponseError();
      return response.json();
    })
    .then((response) => cast<OtherRefundPolicy[]>(response));
