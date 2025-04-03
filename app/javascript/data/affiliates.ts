import { cast } from "ts-safe-cast";

import { assertDefined } from "$app/utils/assert";
import { request, ResponseError } from "$app/utils/request";

import { PaginationProps } from "$app/components/Pagination";
import { Params } from "$app/components/server-components/AffiliatesPage";

export type SelfServeAffiliateProduct = {
  id: number;
  enabled: boolean;
  name: string;
  fee_percent: number | null;
  destination_url?: string | null;
};

type AffiliateProduct = AffiliateProductInfo & { enabled: boolean };

type AffiliateProductInfo = {
  id: number;
  name: string;
  fee_percent: number | null;
  destination_url: string | null;
  referral_url: string;
};

export type Affiliate = {
  id: string;
  email: string;
  affiliate_user_name: string;
  products: AffiliateProductInfo[];
  destination_url: string | null;
  product_referral_url: string;
  fee_percent: number;
  apply_to_all_products: boolean;
};

export type AffiliateRequest = {
  id: string;
  name: string;
  email: string;
  promotion: string;
  date: string;
  state: "created" | "approved" | "ignored";
};

export type AffiliateRequestPayload = {
  id?: string;
  email: string;
  products: AffiliateProduct[];
  fee_percent: number | null;
  apply_to_all_products: boolean;
  destination_url: string | null;
};

type AffiliateResponse = { success: boolean; message?: string };

type AffiliateData = {
  id: string;
  email: string;
  destination_url: string | null;
  affiliate_user_name: string;
  fee_percent: number;
  products: AffiliateProduct[];
};

type AffiliateSignupFormData = { products: readonly SelfServeAffiliateProduct[]; disable_global_affiliate: boolean };
type AffiliateSignupFormResponse = { success: boolean } | { success: false; error: string };
export type AffiliateSignupFormPageData = {
  products: SelfServeAffiliateProduct[];
  creator_subdomain: string;
  disable_global_affiliate: boolean;
  global_affiliate_percentage: number;
  affiliates_disabled_reason: string | null;
};

export type PagedAffiliatesData = {
  affiliate_requests: AffiliateRequest[];
  affiliates: Affiliate[];
  pagination: PaginationProps;
  allow_approve_all_requests: boolean;
  affiliates_disabled_reason: string | null;
};

export async function addAffiliate(data: AffiliateRequestPayload) {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.internal_affiliates_path(),
    data: { affiliate: data },
  });

  if (!response.ok) throw new ResponseError();
  const responseData = cast<AffiliateResponse>(await response.json());
  if (!responseData.success) throw new ResponseError(responseData.message);
}

export async function updateAffiliate(data: AffiliateRequestPayload) {
  const affiliateId = assertDefined(data.id, "Affiliate ID is required");
  const response = await request({
    method: "PATCH",
    accept: "json",
    url: Routes.internal_affiliate_path(affiliateId),
    data: { affiliate: data },
  });

  if (!response.ok) throw new ResponseError();
  const responseData = cast<AffiliateResponse>(await response.json());
  if (!responseData.success) throw new ResponseError(responseData.message);
}
export async function removeAffiliate(id: string) {
  const response = await request({ method: "DELETE", accept: "json", url: Routes.internal_affiliate_path(id) });
  const parsed = cast<{ success: boolean }>(await response.json());
  if (!response.ok || !parsed.success) throw new ResponseError();
}

export function getPagedAffiliates({
  page,
  query,
  sort,
  shouldGetAffiliateRequests,
  abortSignal,
}: Params & { shouldGetAffiliateRequests?: boolean; abortSignal: AbortSignal }) {
  return request({
    method: "GET",
    accept: "json",
    url: Routes.internal_affiliates_path({
      page,
      query,
      sort,
      should_get_affiliate_requests: shouldGetAffiliateRequests ?? false,
    }),
    abortSignal,
  })
    .then((res) => {
      if (!res.ok) throw new ResponseError();
      return res.json();
    })
    .then((json) => cast<PagedAffiliatesData>(json));
}

export async function loadAffiliate(affiliateId: string) {
  const response = await request({
    method: "GET",
    accept: "json",
    url: Routes.internal_affiliate_path(affiliateId),
  });
  if (!response.ok) {
    if (response.status === 404) return null;
    throw new ResponseError();
  }
  return cast<AffiliateData>(await response.json());
}

export async function getOnboardingAffiliateData() {
  const response = await request({
    method: "GET",
    accept: "json",
    url: Routes.onboarding_internal_affiliates_path(),
  });
  if (!response.ok) throw new ResponseError();
  return cast<AffiliateSignupFormPageData>(await response.json());
}

export async function submitAffiliateSignupForm(data: AffiliateSignupFormData) {
  const response = await request({
    method: "PATCH",
    accept: "json",
    url: Routes.affiliate_requests_onboarding_form_path(),
    data,
  });
  const json = cast<AffiliateSignupFormResponse>(await response.json());
  if (!json.success) throw new ResponseError();
  return json;
}

export type AffiliateStatistics = {
  total_volume_cents: number;
  products: Record<number, { volume_cents: number; sales_count: number }>;
};

export const getStatistics = (id: string) =>
  request({
    method: "GET",
    accept: "json",
    url: Routes.statistics_internal_affiliate_path(id),
  })
    .then((res) => {
      if (!res.ok) throw new ResponseError();
      return res.json();
    })
    .then((json) => cast<AffiliateStatistics>(json));
