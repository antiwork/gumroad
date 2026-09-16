import typia from "typia";

import { request, ResponseError } from "$app/utils/request";

export type MarketingAction = {
  id: string;
  channel: string;
  status: "recommended" | "approved" | "queued" | "posted" | "failed" | "cancelled";
  copy: string;
  post_text: string;
  link_url: string | null;
  external_url: string | null;
  error_code: string | null;
  approved_at: string | null;
  posted_at: string | null;
};

export type MarketingChannel = {
  channel: string;
  label: string;
  live: boolean;
  connected?: boolean;
  handle?: string | null;
  connect_path?: string;
  intent_url?: string;
  action?: MarketingAction;
};

type ErrorResponse = { success: false; error: string };

const parse = async <T>(response: Response, assert: (json: unknown) => T): Promise<T> => {
  const json: unknown = await response.json();
  if (!response.ok) {
    const error = typia.is<ErrorResponse>(json) ? json.error : undefined;
    throw new ResponseError(error);
  }
  return assert(json);
};

export const fetchMarketingRecommendations = async (productId: string) => {
  const response = await request({
    url: Routes.product_marketing_actions_path(productId, "json"),
    method: "GET",
    accept: "json",
  });
  return parse(response, (json) => typia.assert<{ channels: MarketingChannel[] }>(json)).then((r) => r.channels);
};

export const approveMarketingAction = async (productId: string, id: string, copy?: string) => {
  const response = await request({
    url: Routes.approve_product_marketing_action_path(productId, id, "json"),
    method: "POST",
    accept: "json",
    data: copy === undefined ? {} : { copy },
  });
  return parse(response, (json) => typia.assert<MarketingAction>(json));
};

export const executeMarketingAction = async (productId: string, id: string) => {
  const response = await request({
    url: Routes.execute_product_marketing_action_path(productId, id, "json"),
    method: "POST",
    accept: "json",
    data: {},
  });
  return parse(response, (json) =>
    typia.assert<{ action: MarketingAction; intent_url: string; connect_path: string }>(json),
  );
};

export const cancelMarketingAction = async (productId: string, id: string) => {
  const response = await request({
    url: Routes.cancel_product_marketing_action_path(productId, id, "json"),
    method: "POST",
    accept: "json",
    data: {},
  });
  return parse(response, (json) => typia.assert<MarketingAction>(json));
};
