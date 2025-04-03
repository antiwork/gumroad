import { cast } from "ts-safe-cast";

import { request, ResponseError } from "$app/utils/request";

export type ExportablePayout = {
  id: string;
  date_formatted: string;
};

export const getExportablePayouts = async (year: number) => {
  const response = await request({
    method: "GET",
    url: Routes.payouts_exportables_path({ year }),
    accept: "json",
  });

  if (!response.ok) throw new ResponseError();

  return cast<{
    selected_year: number;
    years_with_payouts: number[];
    payouts_in_selected_year: ExportablePayout[];
  }>(await response.json());
};

export const exportPayouts = async (payoutIds: string[]) => {
  const response = await request({
    method: "POST",
    url: Routes.payouts_exports_path(),
    data: { payout_ids: payoutIds },
    accept: "json",
  });

  if (!response.ok) throw new ResponseError();
};
