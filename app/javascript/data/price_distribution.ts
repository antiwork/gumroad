import { cast } from "ts-safe-cast";

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

export const fetchPriceDistribution = async (
  uniquePermalink: string,
  { refresh = false, signal }: { refresh?: boolean; signal?: AbortSignal } = {},
): Promise<PriceDistribution> => {
  const baseUrl = Routes.price_check_product_path(uniquePermalink);
  const url = refresh ? `${baseUrl}?refresh=1` : baseUrl;
  const response = await request({ method: "GET", accept: "json", url, abortSignal: signal });
  if (!response.ok) throw new ResponseError();
  return cast<PriceDistribution>(await response.json());
};
