import { cast } from "ts-safe-cast";

import { request } from "$app/utils/request";

export type ChurnSummaryData = {
  current_period: {
    churn_rate: number;
    churned_users: number;
    revenue_lost_cents: number;
    active_at_start: number;
    new_subscriptions: number;
  };
  last_period: {
    churn_rate: number;
    churned_users: number;
    revenue_lost_cents: number;
    active_at_start: number;
    new_subscriptions: number;
  };
  has_subscription_products: boolean;
  start_date: string;
  end_date: string;
};

export type ChurnDataResponse = {
  by_product_and_date: Record<string, {
    churn_rate: number;
    cancelled_count: number;
    revenue_lost_cents: number;
    active_at_start: number;
    new_subscriptions: number;
  }>;
  start_date: string;
  end_date: string;
};

export const fetchChurnSummary = ({ startTime, endTime }: { startTime: string; endTime: string }) => {
  const abort = new AbortController();
  const response = request({
    method: "GET",
    accept: "json",
    url: Routes.analytics_churn_summary_path({ start_time: startTime, end_time: endTime }),
    abortSignal: abort.signal,
  })
    .then((response) => response.json())
    .then((json) => cast<ChurnSummaryData>(json));
  return { response, abort };
};

export const fetchChurnData = ({ startTime, endTime }: { startTime: string; endTime: string }) => {
  const abort = new AbortController();
  const response = request({
    method: "GET",
    accept: "json",
    url: Routes.analytics_churn_data_path({ start_time: startTime, end_time: endTime }),
    abortSignal: abort.signal,
  })
    .then((response) => response.json())
    .then((json) => cast<ChurnDataResponse>(json));
  return { response, abort };
};
