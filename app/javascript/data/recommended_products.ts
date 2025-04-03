import { cast } from "ts-safe-cast";

import { CardProduct } from "$app/parsers/product";
import { request } from "$app/utils/request";

export type RecommendationType =
  | "no_recommendations"
  | "own_products"
  | "directly_affiliated_products"
  | "gumroad_affiliates_products";

export async function getRecommendedProducts(
  cartProductIds: string[],
  limit: number,
  recommendationType?: RecommendationType,
) {
  const response = await request({
    method: "GET",
    accept: "json",
    url: Routes.recommended_products_url({
      cart_product_ids: cartProductIds,
      limit,
      recommendation_type: recommendationType,
    }),
  });
  return cast<CardProduct[]>(await response.json());
}
