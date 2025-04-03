import { cast } from "ts-safe-cast";

import { request } from "$app/utils/request";

export type ThirdPartyAnalytics = {
  disable_third_party_analytics: boolean;
  google_analytics_id: string;
  facebook_pixel_id: string;
  skip_free_sale_analytics: boolean;
  enable_verify_domain_third_party_services: boolean;
  facebook_meta_tag: string;
  snippets: Snippet[];
};

export const SNIPPET_LOCATIONS = ["all", "product", "receipt"] as const;
export type Snippet = {
  id: string | null;
  product: string | null;
  name: string;
  location: (typeof SNIPPET_LOCATIONS)[number];
  code: string;
};

export const saveThirdPartyAnalytics = async (thirdPartyAnalytics: Omit<ThirdPartyAnalytics, "products">) => {
  const response = await request({
    method: "PUT",
    accept: "json",
    url: Routes.settings_third_party_analytics_path(),
    data: { user: thirdPartyAnalytics },
  });
  if (!response.ok) return { success: false, error_message: "Sorry, something went wrong. Please try again." };

  return cast<{ success: false; error_message: string } | { success: true }>(await response.json());
};
