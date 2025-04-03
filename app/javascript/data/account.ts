import { cast } from "ts-safe-cast";

import {
  AnyPaymentMethodParams,
  StripeErrorParams,
  serializeCardParamsIntoQueryParamsObject,
} from "$app/data/payment_method_params";
import { request, ResponseError } from "$app/utils/request";

export type CreateAccountPayload = {
  email: string;
  purchaseId?: string;
  password: string;
  termsAccepted: true;
  cardParams?: AnyPaymentMethodParams | StripeErrorParams | null;
  next?: string | null;
  referrerId?: string | null;
} & ({ buyerSignup: true } | { recaptchaResponse: string | null });
type CreateAccountResult = { redirectLocation: string };

export const createAccount = async (data: CreateAccountPayload): Promise<CreateAccountResult> => {
  const response = await request({
    method: "POST",
    url: Routes.signup_path({ format: "json" }),
    accept: "json",
    data: {
      user: {
        email: data.email,
        purchase_id: data.purchaseId,
        buyer_signup: "buyerSignup" in data,
        password: data.password,
        terms_accepted: data.termsAccepted,
        ...(data.cardParams != null ? serializeCardParamsIntoQueryParamsObject(data.cardParams) : {}),
      },
      next: data.next,
      referral: data.referrerId,
      ...("recaptchaResponse" in data ? { "g-recaptcha-response": data.recaptchaResponse } : {}),
    },
  });
  const responseData = cast<{ success: true; redirect_location: string } | { success: false; error_message: string }>(
    await response.json(),
  );
  if (!responseData.success) throw new ResponseError(responseData.error_message);
  return { redirectLocation: responseData.redirect_location };
};

type AddPurchaseToLibraryResult = { redirectLocation: string };

export const addPurchaseToLibrary = async (data: {
  purchaseId: string;
  purchaseEmail: string;
}): Promise<AddPurchaseToLibraryResult> => {
  const response = await request({
    method: "POST",
    url: Routes.add_purchase_to_library_path({ format: "json" }),
    accept: "json",
    data: { user: { purchase_id: data.purchaseId, purchase_email: data.purchaseEmail } },
  });

  const responseData = cast<{ success: true; redirect_location: string } | { success: false }>(await response.json());
  if (!responseData.success) throw new ResponseError();
  return { redirectLocation: responseData.redirect_location };
};
