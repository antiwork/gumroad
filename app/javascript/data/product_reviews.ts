import { cast } from "ts-safe-cast";

import { request, ResponseError } from "$app/utils/request";

import { PaginationProps } from "$app/components/Pagination";

export const setProductRating = async ({
  permalink,
  purchaseId,
  purchaseEmailDigest,
  rating,
  message,
  videoOptions,
}: {
  permalink: string;
  purchaseId: string;
  purchaseEmailDigest: string;
  rating: number;
  message?: string | null;
  videoOptions?: {
    create?: { url: string; thumbnail_signed_id: string | undefined };
    destroy?: { id: string };
  };
}) => {
  const response = await request({
    method: "PUT",
    url: Routes.product_reviews_set_path(),
    accept: "json",
    data: {
      link_id: permalink,
      purchase_id: purchaseId,
      purchase_email_digest: purchaseEmailDigest,
      rating,
      message,
      video_options: videoOptions,
    },
  });

  const json = cast<
    | {
        success: true;
        review: {
          rating: number;
          message: string | null;
          video: { id: string; thumbnail_url: string | null } | null;
        };
      }
    | { success: false; message: string }
  >(await response.json());
  if (!json.success) throw new ResponseError(json.message);

  return json.review;
};

export type Review = {
  id: string;
  rating: number;
  message: string | null;
  rater: { name: string; avatar_url: string };
  purchase_id: string;
  is_new: boolean;
  response: {
    message: string;
  } | null;
  video: {
    id: string;
    thumbnail_url: string | null;
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

export const getStreamingUrls = async (id: string) => {
  const response = await request({
    method: "GET",
    url: Routes.product_review_video_streaming_urls_path(id),
    accept: "json",
  });

  if (!response.ok) throw new ResponseError();

  return cast<{ streaming_urls: string[] }>(await response.json());
};

export type ReviewVideoUploadContext = {
  aws_access_key_id: string;
  s3_url: string;
  user_id: string;
};

export const getReviewVideoUploadContext = async (): Promise<ReviewVideoUploadContext> => {
  const response = await request({
    method: "GET",
    url: Routes.product_review_videos_upload_context_path(),
    accept: "json",
  });

  if (!response.ok) throw new ResponseError();

  return cast<ReviewVideoUploadContext>(await response.json());
};
