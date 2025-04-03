import { cast } from "ts-safe-cast";

import { request, ResponseError } from "$app/utils/request";

import { PaginationProps } from "$app/components/Pagination";

export const setProductRating = async ({
  permalink,
  purchaseId,
  purchaseEmailDigest,
  rating,
  message,
}: {
  permalink: string;
  purchaseId: string;
  purchaseEmailDigest: string;
  rating: number;
  message?: string | null;
}) => {
  const response = await request({
    method: "PUT",
    url: Routes.product_reviews_set_path(),
    accept: "json",
    data: { link_id: permalink, purchase_id: purchaseId, purchase_email_digest: purchaseEmailDigest, rating, message },
  });

  const json = cast<{ success: true } | { success: false; message: string }>(await response.json());
  if (!json.success) throw new ResponseError(json.message);
};

export type Review = {
  id: string;
  rating: number;
  message: string;
  rater: { name: string; avatar_url: string };
  purchase_id: string;
  is_new: boolean;
  response: {
    message: string;
    created_at: {
      date: string;
      humanized: string;
    };
  } | null;
};

export const getReviews = async (productId: string, page: number) => {
  const response = await request({
    method: "GET",
    url: Routes.product_reviews_path({ product_id: productId, page }),
    accept: "json",
  });

  if (!response.ok) throw new ResponseError();

  return cast<{ reviews: Review[]; pagination: PaginationProps }>(await response.json());
};

export const getReview = async (reviewId: string): Promise<{ review: Review }> => {
  const response = await request({
    method: "GET",
    url: Routes.product_review_path(reviewId),
    accept: "json",
  });

  if (!response.ok) throw new ResponseError();

  return cast<{ review: Review }>(await response.json());
};
