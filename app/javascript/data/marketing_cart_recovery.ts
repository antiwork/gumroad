import { cast } from "$app/utils/cast";
import { isRecord, isString } from "$app/utils/guards";
import { request, ResponseError } from "$app/utils/request";

export type MarketingCartRecovery = {
  available: boolean;
  blocked_reason: string | null;
  enabled: boolean;
  can_toggle: boolean;
  activation_token: string;
  subject: string;
  message: string | null;
  delay_hours: number;
  workflows: { name: string; url: string; scope: string; enabled: boolean }[];
};

type ErrorResponse = { success: false; error: string };

const isErrorResponse = (json: unknown): json is ErrorResponse =>
  isRecord(json) && json.success === false && isString(json.error);

const parse = async (response: Response): Promise<MarketingCartRecovery> => {
  if (!response.ok) {
    const json: unknown = await response.json().catch(() => null);
    throw new ResponseError(isErrorResponse(json) ? json.error : undefined);
  }
  return cast<MarketingCartRecovery>(await response.json());
};

export const fetchCartRecovery = async (productId: string) => {
  const response = await request({
    url: Routes.product_marketing_abandoned_cart_path(productId, "json"),
    method: "GET",
    accept: "json",
  });
  return parse(response);
};

export const updateCartRecovery = async (productId: string, enabled: boolean, activationToken?: string) => {
  const response = await request({
    url: Routes.product_marketing_abandoned_cart_path(productId, "json"),
    method: "PUT",
    accept: "json",
    data: { enabled, activation_token: activationToken },
  });
  return parse(response);
};
