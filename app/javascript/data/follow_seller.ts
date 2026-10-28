import { cast } from "$app/utils/cast";
import { assertResponseError, request } from "$app/utils/request";

type FollowResponse = { success: true; message: string; confirmed: boolean } | { success: false; message?: string };

export const followSeller = async (
  email: string,
  seller_id: string,
  // The CAPTCHA token, for sellers whose subscribe form requires one. Sent under
  // the name Google's verification API expects, which is also what the server
  // reads it from.
  recaptchaResponse: string | null = null,
  // The product a waitlist signup came from. The server resolves it among the seller's own
  // products, so a posted id can never attach the follow to someone else's product.
  product_id: string | null = null,
): Promise<FollowResponse> => {
  try {
    const response = await request({
      method: "POST",
      accept: "json",
      url: Routes.follow_user_path(),
      data: { email, seller_id, "g-recaptcha-response": recaptchaResponse, product_id },
    });
    return cast<FollowResponse>(await response.json());
  } catch (e) {
    assertResponseError(e);
    return { success: false };
  }
};
