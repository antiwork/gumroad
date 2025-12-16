import { cast } from "ts-safe-cast";

import { request, ResponseError } from "$app/utils/request";

import { PaginationProps } from "$app/components/Pagination";

export type SortKey = "affiliate_user_name" | "products" | "fee_percent" | "volume_cents";

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
