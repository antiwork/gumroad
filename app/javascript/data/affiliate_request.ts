import { cast } from "ts-safe-cast";

import { request, ResponseError } from "$app/utils/request";

type AffiliateRequestResponse =
  | { success: true; requester_has_existing_account: boolean }
  | { success: false; error: string };

export async function submitAffiliateRequest(data: { name: string; email: string; promotion_text: string }) {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.custom_domain_create_affiliate_request_path(),
    data: { affiliate_request: data },
  });
  const json = cast<AffiliateRequestResponse>(await response.json());
  if (!json.success) throw new ResponseError(json.error);
  return json;
}

export async function updateAffiliateRequest(id: string, action: "ignore" | "approve") {
  const response = await request({
    method: "PATCH",
    accept: "json",
    url: Routes.affiliate_request_path(id),
    data: { affiliate_request: { action } },
  });
  const json = cast<AffiliateRequestResponse>(await response.json());
  if (!json.success) throw new ResponseError(json.error);
  return json;
}

export async function approvePendingAffiliateRequests(): Promise<void> {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.approve_all_affiliate_requests_path(),
  });
  if (!response.ok || !cast<{ success: boolean }>(await response.json()).success) throw new ResponseError();
}
