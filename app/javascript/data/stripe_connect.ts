import { cast } from "ts-safe-cast";

import { request, ResponseError } from "$app/utils/request";

export const createAccountSession = async () => {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.stripe_account_sessions_url(),
  });

  const responseData = cast<{ success: true; client_secret: string } | { success: false; error_message: string }>(
    await response.json(),
  );

  if (!responseData.success) throw new ResponseError(responseData.error_message);

  return responseData.client_secret;
};
