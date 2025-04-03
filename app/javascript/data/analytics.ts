import { cast } from "ts-safe-cast";

import { request } from "$app/utils/request";

export type AnalyticsDataByReferral = {
  dates_and_months: {
    date: string;
    month: string;
    month_index: number;
  }[];
  start_date: string;
  end_date: string;
  by_referral: {
    views: Record<string, Record<string, number[]>>;
    sales: Record<string, Record<string, number[]>>;
    totals: Record<string, Record<string, number[]>>;
  };
};

export const fetchAnalyticsDataByReferral = ({ startTime, endTime }: { startTime: string; endTime: string }) => {
  const abort = new AbortController();
  const response = request({
    method: "GET",
    accept: "json",
    url: Routes.analytics_data_by_referral_path({ start_time: startTime, end_time: endTime }),
    abortSignal: abort.signal,
  })
    .then((response) => response.json())
    .then((json) => cast<AnalyticsDataByReferral>(json));
  return { response, abort };
};

// CountryData values can be int (country total), int[] (breakdown by states in country)
// or undefined (ex: when country has views but no sales)
export type LocationDataValue = number | number[] | undefined;
export type LocationData = Record<string, Record<string, LocationDataValue>>;
export type AnalyticsDataByState = {
  by_state: {
    sales: LocationData;
    totals: LocationData;
    views: LocationData;
  };
};

export const fetchAnalyticsDataByState = ({ startTime, endTime }: { startTime: string; endTime: string }) => {
  const abort = new AbortController();
  const response = request({
    method: "GET",
    accept: "json",
    url: Routes.analytics_data_by_state_path({ start_time: startTime, end_time: endTime }),
    abortSignal: abort.signal,
  })
    .then((response) => response.json())
    .then((json) => cast<AnalyticsDataByState>(json));
  return { response, abort };
};
