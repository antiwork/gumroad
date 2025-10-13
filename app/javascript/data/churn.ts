import { cast } from "ts-safe-cast";

import { request } from "$app/utils/request";

export type ChurnMetrics = {
  customer_churn_rate: number;
  last_period_churn_rate: number;
  churned_subscribers: number;
  churned_mrr_cents: number;
};

export type ChurnDailyData = {
  date: string;
  customer_churn_rate: number;
  churned_subscribers: number;
  churned_mrr_cents: number;
};

export type ChurnData = {
  start_date: string;
  end_date: string;
  metrics: ChurnMetrics;
  daily_data: ChurnDailyData[];
};

export const fetchChurnData = ({
  startTime,
  endTime,
}: {
  startTime: string;
  endTime: string;
}): { response: Promise<ChurnData>; abort: AbortController } => {
  const abort = new AbortController();

  const response = request({
    method: "GET",
    accept: "json",
    url: Routes.churn_data_path({ start_time: startTime, end_time: endTime }),
    abortSignal: abort.signal,
  })
    .then((response) => response.json())
    .then((json) => cast<ChurnData>(json));

  return { response, abort };
};
