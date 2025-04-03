import { cast } from "ts-safe-cast";

import { request, ResponseError } from "$app/utils/request";

export type Product = {
  recommendable: boolean;
  name: string;
  short_url: string;
  formatted_price: string;
};

export const searchGlobalAffiliatesProductEligibility = async ({ query }: { query: string }): Promise<Product> => {
  const response = await request({
    method: "GET",
    accept: "json",
    url: Routes.global_affiliates_product_eligibility_path(query),
  });
  if (!response.ok) throw new ResponseError();
  const responseData = cast<{ success: true; product: Product } | { success: false; error: string }>(
    await response.json(),
  );
  if (!responseData.success) throw new ResponseError(responseData.error);
  return responseData.product;
};
