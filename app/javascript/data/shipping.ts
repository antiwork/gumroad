import { cast } from "ts-safe-cast";

import { request, TimeoutError } from "$app/utils/request";

type ShippingAddress = {
  street_address: string;
  city: string;
  state: string;
  zip_code: string;
  country: string;
};

type AddressWithoutCountry = {
  street_address: string;
  city: string;
  state: string;
  zip_code: string;
};

export type VerificationResult =
  | { type: "done"; verifiedAddress: AddressWithoutCountry }
  | {
      type: "verification-required";
      suggestedAddress: AddressWithoutCountry;
      formattedSuggestedAddress: string;
      formattedOriginalAddress: string;
    }
  | {
      type: "invalid";
      message: string;
    }
  | { type: "error" };

export const verifyShippingAddress = async (shippingAddress: ShippingAddress): Promise<VerificationResult> => {
  try {
    const response = await request({
      method: "POST",
      accept: "json",
      url: Routes.verify_shipping_address_path(),
      data: {
        street_address: shippingAddress.street_address,
        city: shippingAddress.city,
        state: shippingAddress.state,
        zip_code: shippingAddress.zip_code,
        country: shippingAddress.country,
      },
    });

    if (response.ok) {
      const responseData = cast<
        | VerifyShippingAddressErrorResponse
        | VerifyShippingAddressVerificationCaseResponse
        | VerifyShippingAddressSuccessResponse
      >(await response.json());
      if (responseData.success) {
        return {
          type: "done",
          verifiedAddress: {
            street_address: responseData.street_address,
            city: responseData.city,
            state: responseData.state,
            zip_code: responseData.zip_code,
          },
        };
      }
      if ("easypost_verification_required" in responseData) {
        return {
          type: "verification-required",
          suggestedAddress: {
            street_address: responseData.street_address,
            city: responseData.city,
            state: responseData.state,
            zip_code: responseData.zip_code,
          },
          formattedOriginalAddress: responseData.formatted_original_address,
          formattedSuggestedAddress: responseData.formatted_address,
        };
      }
      return { type: "invalid", message: responseData.error_message };
    }
    return { type: "error" };
  } catch (reason) {
    if (reason instanceof TimeoutError) {
      return { type: "error" };
    }
    throw reason;
  }
};

type VerifyShippingAddressErrorResponse = { success: false; error_message: string };

type VerifyShippingAddressVerificationCaseResponse = {
  success: false;
  easypost_verification_required: boolean;
  street_address: string;
  city: string;
  state: string;
  zip_code: string;
  formatted_address: string;
  formatted_original_address: string;
};

type VerifyShippingAddressSuccessResponse = {
  success: true;
  street_address: string;
  city: string;
  state: string;
  zip_code: string;
};
