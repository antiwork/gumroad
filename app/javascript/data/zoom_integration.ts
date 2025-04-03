import { cast } from "ts-safe-cast";

import { request } from "$app/utils/request";

type AccountInfo =
  | { ok: true; userId: string; email: string; accessToken: string; refreshToken: string }
  | { ok: false };
export const fetchAccountInfo = async (code: string): Promise<AccountInfo> => {
  const response = await request({
    method: "GET",
    url: Routes.account_info_integrations_zoom_index_path({ format: "json", code }),
    accept: "json",
  });
  if (response.ok) {
    const responseData = cast<
      | {
          success: true;
          user_id: string;
          email: string;
          access_token: string;
          refresh_token: string;
        }
      | { success: false }
    >(await response.json());
    if (responseData.success) {
      return {
        ok: true,
        userId: responseData.user_id,
        email: responseData.email,
        accessToken: responseData.access_token,
        refreshToken: responseData.refresh_token,
      };
    }
    return { ok: false };
  }
  return { ok: false };
};
