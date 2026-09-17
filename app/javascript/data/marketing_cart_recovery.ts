import typia from "typia";

import { request, ResponseError } from "$app/utils/request";

export type MarketingCartRecovery = {
  available: boolean;
  blocked_reason: string | null;
  enabled: boolean;
  account_wide: boolean;
  subject: string;
  delay_hours: number;
  workflow_url: string | null;
};

type ErrorResponse = { success: false; error: string };

const parse = async (response: Response): Promise<MarketingCartRecovery> => {
  const json: unknown = await response.json();
  if (!response.ok) {
    const error = typia.is<ErrorResponse>(json) ? json.error : undefined;
    throw new ResponseError(error);
  }
  return typia.assert<MarketingCartRecovery>(json);
};

export const fetchCartRecovery = async (productId: string) => {
  const response = await request({
    url: Routes.product_marketing_abandoned_cart_path(productId, "json"),
    method: "GET",
    accept: "json",
  });
  return parse(response);
};

// The wanted state travels with the request, so a second tap on a stale card cannot undo
// the first.
export const updateCartRecovery = async (productId: string, enabled: boolean) => {
  const response = await request({
    url: Routes.product_marketing_abandoned_cart_path(productId, "json"),
    method: "PUT",
    accept: "json",
    data: { enabled },
  });
  return parse(response);
};
