import { cast } from "ts-safe-cast";

import {
  AnyPaymentMethodParams,
  StripeErrorParams,
  serializeCardParamsIntoQueryParamsObject,
} from "$app/data/payment_method_params";
import { request } from "$app/utils/request";

export type UpdateSubscriptionPayload = {
  cardParams: AnyPaymentMethodParams | StripeErrorParams | null;
  recaptchaResponse: string | null;
  subscription_id: string;
  price_id?: string | undefined;
  variants: string[];
  quantity: number;
  contact_info: {
    email: string;
    full_name: string;
    street_address: string;
    state: string;
    zip_code: string;
    country: string;
    city: string;
  };
  declined: boolean;
  perceived_price_cents?: number;
  perceived_upgrade_price_cents: number;
  // for PWYW tier
  price_range?: number | undefined;
};

export const updateSubscription = async (
  data: UpdateSubscriptionPayload,
): Promise<
  | { type: "done"; message: string; next: string | null }
  | { type: "error"; message: string }
  | {
      type: "requires_card_action";
      client_secret: string;
      purchase: { id: string; stripe_connect_account_id: string | null };
    }
> => {
  const { subscription_id, cardParams, recaptchaResponse, ...rest } = data;

  const jsonData = {
    ...rest,
    ...(cardParams ? serializeCardParamsIntoQueryParamsObject(cardParams) : { use_existing_card: true }),
    "g-recaptcha-response": recaptchaResponse,
  };

  const response = await request({
    url: Routes.subscription_path(subscription_id),
    method: "PUT",
    accept: "json",
    data: jsonData,
  });

  if (response.ok) {
    const responseData = cast<UpdateSubscriptionResponse>(await response.json());
    if (responseData.success && !("requires_card_action" in responseData)) {
      return { type: "done", message: responseData.success_message, next: responseData.next ?? null };
    } else if (responseData.success && "requires_card_action" in responseData) {
      return {
        type: "requires_card_action",
        client_secret: responseData.client_secret,
        purchase: responseData.purchase,
      };
    }
    return { type: "error", message: responseData.error_message };
  }
  return { type: "error", message: "Sorry, something went wrong." };
};
type UpdateSubscriptionResponse =
  | { success: false; error_message: string }
  | { success: true; success_message: string; next?: string | null }
  | {
      success: true;
      requires_card_action: true;
      client_secret: string;
      purchase: { id: string; stripe_connect_account_id: string | null };
    };
