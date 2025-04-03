import { cast } from "ts-safe-cast";

import { GCAL_OAUTH_URL } from "$app/utils/integrations";
import { request, ResponseError } from "$app/utils/request";

type AccountInfo = { accessToken: string; refreshToken: string; email: string };
type Calendar = { id: string; summary: string };
export const fetchAccountInfo = async (code: string): Promise<AccountInfo> => {
  const response = await request({
    method: "GET",
    url: Routes.account_info_integrations_google_calendar_index_path({ format: "json", code }),
    accept: "json",
  });
  const responseData = cast<
    | {
        success: true;
        access_token: string;
        refresh_token: string;
        email: string;
      }
    | { success: false }
  >(await response.json());
  if (!responseData.success) throw new ResponseError();
  return {
    accessToken: responseData.access_token,
    refreshToken: responseData.refresh_token,
    email: responseData.email,
  };
};

export const fetchCalendarList = async (accessToken: string, refreshToken: string): Promise<Calendar[]> => {
  const response = await request({
    method: "GET",
    url: Routes.calendar_list_integrations_google_calendar_index_path({
      format: "json",
      access_token: accessToken,
      refresh_token: refreshToken,
    }),
    accept: "json",
  });
  const responseData = cast<{ success: true; calendar_list: { id: string; summary: string }[] } | { success: false }>(
    await response.json(),
  );
  if (!responseData.success) throw new ResponseError();
  return responseData.calendar_list;
};

export const getOAuthUrl = (googleClientId: string): string => {
  const url = new URL(GCAL_OAUTH_URL);
  url.searchParams.set("response_type", "code");
  url.searchParams.set(
    "scope",
    "https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/calendar",
  );
  url.searchParams.set("access_type", "offline");
  url.searchParams.set("approval_prompt", "force");
  url.searchParams.set("redirect_uri", Routes.oauth_redirect_integrations_google_calendar_index_url());
  url.searchParams.set("client_id", googleClientId);
  return url.toString();
};
