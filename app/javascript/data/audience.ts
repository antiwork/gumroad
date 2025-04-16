import { cast } from "ts-safe-cast";

import { request, ResponseError } from "$app/utils/request";

export type AudienceDataByDate = {
  dates: string[];
  start_date: string;
  end_date: string;
  by_date: {
    new_followers: number[];
    followers_removed: number[];
    totals: number[];
  };
  first_follower_date: string;
  new_followers: number;
};

export const fetchAudienceDataByDate = ({ startTime, endTime }: { startTime: string; endTime: string }) => {
  const abort = new AbortController();
  const response = request({
    method: "GET",
    accept: "json",
    url: Routes.audience_data_by_date_path(startTime, endTime),
    abortSignal: abort.signal,
  })
    .then((response) => response.json())
    .then((json) => cast<AudienceDataByDate>(json));
  return { response, abort };
};

export const sendSubscribersReport = async ({
  options,
}: {
  options: { followers: boolean; customers: boolean; affiliates: boolean };
}) => {
  const response = await request({
    url: Routes.audience_export_path(),
    method: "POST",
    data: {
      options,
    },
    accept: "json",
  });
  if (!response.ok) throw new ResponseError();
};
