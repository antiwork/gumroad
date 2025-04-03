import { request, ResponseError } from "$app/utils/request";

export const createInstantPayout = async (date: string) => {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.instant_payouts_path(),
    data: {
      date,
    },
  });

  if (!response.ok) throw new ResponseError("Failed to send instant payout");
};
