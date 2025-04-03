import { cast } from "ts-safe-cast";

import { request, ResponseError } from "$app/utils/request";

type SignUpAndAddPurchaseRequestData = {
  buyerSignup: true;
  termsAccepted: true;
  purchaseId: string;
  email: string;
  password: string;
};

type SignUpResponse = { success: true } | { success: false; error_message: string };

export const signupAndAddPurchaseToLibrary = async (data: SignUpAndAddPurchaseRequestData) => {
  const response = await request({
    method: "POST",
    url: Routes.save_to_library_path({ format: "json" }),
    accept: "json",
    data: {
      user: {
        email: data.email,
        purchase_id: data.purchaseId,
        buyer_signup: data.buyerSignup,
        password: data.password,
        terms_accepted: data.termsAccepted,
      },
    },
  });

  const responseData = cast<SignUpResponse>(await response.json());
  if (!responseData.success) throw new ResponseError(responseData.error_message);
};
