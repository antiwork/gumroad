import { cast } from "ts-safe-cast";

import { RecommendationType } from "$app/data/recommended_products";
import { request, ResponseError } from "$app/utils/request";

export type CustomField = {
  id: string | null;
  type: "text" | "checkbox" | "terms";
  name: string;
  required: boolean;
  global: boolean;
  collect_per_product: boolean;
  products: string[];
};

export const updateCheckoutForm = async ({
  user: { displayOfferCodeField, recommendationType, tippingEnabled },
  customFields,
}: {
  user: {
    displayOfferCodeField: boolean;
    recommendationType: RecommendationType;
    tippingEnabled: boolean | null;
  };
  customFields: CustomField[];
}): Promise<{ custom_fields: CustomField[] }> => {
  const response = await request({
    method: "PUT",
    accept: "json",
    url: Routes.checkout_form_path(),
    data: {
      user: {
        display_offer_code_field: displayOfferCodeField,
        recommendation_type: recommendationType,
        tipping_enabled: tippingEnabled,
      },
      custom_fields: customFields,
    },
  });
  const json: unknown = await response.json();
  if (response.ok) return cast(json);
  throw new ResponseError(cast<{ error_message: string }>(json).error_message);
};
