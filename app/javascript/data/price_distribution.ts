import typia from "typia";

import { ResponseError, request } from "$app/utils/request";

export type PriceDistributionTier = "with_taxonomy" | "broadened" | "insufficient";

export type PriceDistributionBin = {
  from_cents: number;
  to_cents: number;
  count: number;
};

export type PriceDistributionSummary = {
  median_cents: number;
  p25_cents: number;
  p75_cents: number;
  mean_cents: number;
};

export type PriceDistributionHistogram = {
  interval_cents: number;
  bins: PriceDistributionBin[];
};

export type PriceDistribution =
  | {
      status: "ok";
      tier: "with_taxonomy" | "broadened";
      match_count: number;
      taxonomy_label: string | null;
      currency_code: string;
      current_price_cents: number;
      summary: PriceDistributionSummary;
      histogram: PriceDistributionHistogram;
      computed_at: string;
    }
  | {
      status: "insufficient_data";
      tier: "insufficient";
      match_count: number;
      taxonomy_label: null;
      currency_code: string;
      current_price_cents: number;
      summary: null;
      histogram: null;
      computed_at: string;
    };

export type PriceCheckOverrides = {
  name: string;
  description: string;
  taxonomy_id: string | null;
  native_type: string;
  currency_code: string;
};

export const fetchPriceDistribution = async (
  uniquePermalink: string,
  { refresh = false, overrides, signal }: { refresh?: boolean; overrides: PriceCheckOverrides; signal?: AbortSignal },
): Promise<PriceDistribution> => {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.price_check_product_path(uniquePermalink),
    data: { refresh, overrides },
    abortSignal: signal,
  });
  if (!response.ok) throw new ResponseError();
  return typia.assert<PriceDistribution>(await response.json());
};
