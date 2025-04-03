import { cast } from "ts-safe-cast";

import { RecurrenceId } from "$app/utils/recurringPricing";
import { request, ResponseError } from "$app/utils/request";

type sendSamplePriceChangeEmailRequestArgs = {
  productPermalink: string;
  tierId: string;
  newPrice: { recurrence: RecurrenceId; amount: string };
  effectiveDate: string;
  customMessage: string | null;
};

export const sendSamplePriceChangeEmail = async ({
  productPermalink,
  tierId,
  newPrice,
  effectiveDate,
  customMessage,
}: sendSamplePriceChangeEmailRequestArgs): Promise<void> => {
  const response = await request({
    method: "POST",
    url: Routes.sample_membership_price_change_email_path(productPermalink),
    accept: "json",
    data: customMessage
      ? { ...newPrice, tier_id: tierId, effective_date: effectiveDate, custom_message: customMessage }
      : { ...newPrice, tier_id: tierId, effective_date: effectiveDate },
  });
  if (response.ok) {
    const responseData = cast<{ success: true } | { success: false; error?: string }>(await response.json());
    if (!responseData.success) throw new ResponseError(responseData.error || "Error sending sample price change email");
  } else {
    throw new ResponseError("Error sending sample price change email");
  }
};
