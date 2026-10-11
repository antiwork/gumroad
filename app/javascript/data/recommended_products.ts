import { CardProduct } from "$app/parsers/product";
import { isOneOf } from "$app/utils/guards";
import { request, readJson } from "$app/utils/request";

const recommendationTypes = [
  "no_recommendations",
  "own_products",
  "directly_affiliated_products",
  "gumroad_affiliates_products",
] as const;
export type RecommendationType = (typeof recommendationTypes)[number];
export const isRecommendationType = (value: unknown): value is RecommendationType =>
  isOneOf(value, recommendationTypes);

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
  return await readJson<CardProduct[]>(response);
}
