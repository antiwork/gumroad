import * as React from "react";

import { Review as ReviewType } from "$app/data/product_reviews";

import { Icon } from "$app/components/Icons";
import { RatingStars } from "$app/components/RatingStars";
import { ReviewResponseForm } from "$app/components/ReviewResponseForm";
import { ReviewVideoPlayer } from "$app/components/ReviewVideoPlayer";
import { WithTooltip } from "$app/components/WithTooltip";

export type Seller = {
  id: string;
  name: string;
  avatar_url: string;
  profile_url: string;
};

const ReviewUserAttribution = ({
  avatarUrl,
  name,
  isBuyer,
}: {
  avatarUrl: string;
  name: string;
  isBuyer?: boolean;
}) => (
  <section className="flex items-center gap-2">
    <img className="user-avatar" src={avatarUrl} />
    <h5>{name}</h5>
    {isBuyer ? (
      <WithTooltip tip="Verified Buyer">
        <Icon name="solid-check-circle" aria-label="Verified Buyer" />
      </WithTooltip>
    ) : null}
  </section>
);

export const Review = ({
  review: initialReview,
  seller,
  canRespond,
  hideResponse = false,
}: {
  review: ReviewType;
  seller: Seller | null;
  canRespond: boolean;
  hideResponse?: boolean;
}) => {
  const [review, setReview] = React.useState(initialReview);
  const [isEditing, setIsEditing] = React.useState(false);

  return (
    <>
      <section className="override grid gap-2">
        <span
          className="flex shrink-0 items-center gap-1"
          aria-label={`${review.rating} ${review.rating === 1 ? "star" : "stars"}`}
        >
          <RatingStars rating={review.rating} />
          {review.is_new ? <span className="pill small primary">New</span> : null}
        </span>
        {review.message ? <p className="m-0">{review.message}</p> : null}
        {review.video ? <ReviewVideoPlayer videoId={review.video.id} thumbnail={review.video.thumbnail_url} /> : null}
        <section className="flex flex-wrap items-center gap-1">
          <ReviewUserAttribution avatarUrl={review.rater.avatar_url} name={review.rater.name} isBuyer />
        </section>
      </section>
      {review.response && !isEditing && !hideResponse ? (
        <section className="override ml-4 grid gap-2">
          <p className="m-0">{review.response.message}</p>
          <section className="flex flex-wrap items-center gap-1">
            {seller ? <ReviewUserAttribution avatarUrl={seller.avatar_url} name={seller.name} /> : null}
            <span className="pill small">Creator</span>
          </section>
        </section>
      ) : null}
      {canRespond && !hideResponse ? (
        <section className="ml-4">
          <ReviewResponseForm
            message={review.response?.message}
            purchaseId={review.purchase_id}
            onChange={(response) =>
              setReview((prev) => ({
                ...prev,
                response,
              }))
            }
            onEditingChange={setIsEditing}
            buttonProps={{ small: true }}
          />
        </section>
      ) : null}
    </>
  );
};
