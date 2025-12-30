import { cast } from "ts-safe-cast";

import { ResponseError, request } from "$app/utils/request";

export const renewPassword = async (email: string) => {
  const response = await request({
    method: "POST",
    url: Routes.forgot_password_path(),
    accept: "json",
    data: { user: { email } },
  });
  if (!response.ok) {
    const { error_message } = cast<{ error_message: string }>(await response.json());
    throw new ResponseError(error_message);
  }
};

export const twoFactorLogin = async (data: { user_id: string; token: string; next: string | null }) => {
  const response = await request({
    method: "POST",
    // Passing user_id in the query string so that Rack::Attack picks it up in params (Rack doesn't parse JSON bodies)
    url: Routes.two_factor_path("json", { user_id: data.user_id }),
    accept: "json",
    data: { token: data.token, next: data.next },
  });
  if (!response.ok) {
    const { error_message } = cast<{ error_message: string }>(await response.json());
    throw new ResponseError(error_message);
  }
  const { redirect_location } = cast<{ redirect_location: string }>(await response.json());
  return { redirectLocation: redirect_location };
};

export const resendTwoFactorToken = async (userId: string) => {
  const response = await request({
    method: "POST",
    // Passing user_id in the query string so that Rack::Attack picks it up in params (Rack doesn't parse JSON bodies)
    url: Routes.resend_authentication_token_path("json", { user_id: userId }),
    accept: "json",
  });
  if (!response.ok) {
    throw new ResponseError();
  }
};
