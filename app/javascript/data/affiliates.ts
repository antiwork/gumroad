import { cast } from "ts-safe-cast";

import { request, ResponseError } from "$app/utils/request";

export type SelfServeAffiliateProduct = {
  id: number;
  enabled: boolean;
  name: string;
  fee_percent: number | null;
  destination_url?: string | null;
};

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

export type AffiliateStatistics = {
  total_volume_cents: number;
  products: Record<number, { volume_cents: number; sales_count: number }>;
};

export const getStatistics = (id: string) =>
  request({
    method: "GET",
    accept: "json",
    url: Routes.statistics_affiliate_path(id),
  })
    .then((res) => {
      if (!res.ok) throw new ResponseError();
      return res.json();
    })
    .then((json) => cast<AffiliateStatistics>(json));
