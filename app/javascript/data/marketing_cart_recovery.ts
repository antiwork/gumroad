import typia from "typia";

import { request, ResponseError } from "$app/utils/request";

export type MarketingCartRecovery = {
  available: boolean;
  blocked_reason: string | null;
  enabled: boolean;
  can_toggle: boolean;
  subject: string;
  message: string | null;
  delay_hours: number;
  workflows: { name: string; url: string; scope: string; enabled: boolean }[];
};

type ErrorResponse = { success: false; error: string };

const parse = async (response: Response): Promise<MarketingCartRecovery> => {
  if (!response.ok) {
    const json: unknown = await response.json().catch(() => null);
    throw new ResponseError(typia.is<ErrorResponse>(json) ? json.error : undefined);
  }
  return typia.assert<MarketingCartRecovery>(await response.json());
};

export const fetchCartRecovery = async (productId: string) => {
  const response = await request({
    url: Routes.product_marketing_abandoned_cart_path(productId, "json"),
    method: "GET",
    accept: "json",
  });
  return parse(response);
};

export const updateCartRecovery = async (productId: string, enabled: boolean) => {
  const response = await request({
    url: Routes.product_marketing_abandoned_cart_path(productId, "json"),
    method: "PUT",
    accept: "json",
    data: { enabled },
  });
  return parse(response);
};
