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
