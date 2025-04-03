import { cast } from "ts-safe-cast";

import { request, ResponseError } from "$app/utils/request";

export type CallAvailability = {
  start_time: Date;
  end_time: Date;
};

export async function getRemainingCallAvailabilities(permalink: string) {
  const response = await request({
    method: "GET",
    url: Routes.product_remaining_call_availabilities_path(permalink, "json"),
    accept: "json",
  });

  if (!response.ok) throw new ResponseError();

  const rawAvailabilities = cast<{ call_availabilities: { start_time: string; end_time: string }[] }>(
    await response.json(),
  );

  return rawAvailabilities.call_availabilities.map((availability) => ({
    start_time: new Date(availability.start_time),
    end_time: new Date(availability.end_time),
  }));
}
