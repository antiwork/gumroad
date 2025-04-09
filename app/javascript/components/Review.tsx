import * as React from "react";

import { Review as ReviewType } from "$app/data/product_reviews";

import { Icon } from "$app/components/Icons";
import { RatingStars } from "$app/components/RatingStars";
import { ReviewResponseForm } from "$app/components/ReviewResponseForm";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { WithTooltip } from "$app/components/WithTooltip";

export type Seller = {
  id: string;
  name: string;
  avatar_url: string;
  profile_url: string;
};

const DateWithTooltip = ({ date, humanized }: { date: string; humanized: string }) => {
  const userAgentInfo = useUserAgentInfo();

  return (
    <WithTooltip
      tip={new Date(date).toLocaleDateString(userAgentInfo.locale, {
        month: "long",
        day: "numeric",
        year: "numeric",
      })}
    >
      <time className="text-muted" style={{ cursor: "default" }}>
        {humanized}
      </time>
    </WithTooltip>
  );
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
  <section style={{ display: "flex", alignItems: "center", gap: "var(--spacer-2)" }}>
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
      <section style={{ display: "grid", gap: "var(--spacer-2)" }}>
        <span className="rating" aria-label={`${review.rating} ${review.rating === 1 ? "star" : "stars"}`}>
          <RatingStars rating={review.rating} />
          {review.is_new ? <span className="pill small primary">New</span> : null}
        </span>
        <p style={{ margin: 0 }}>{review.message}</p>
        <section style={{ display: "flex", gap: "var(--spacer-1)", alignItems: "center", flexWrap: "wrap" }}>
          <ReviewUserAttribution avatarUrl={review.rater.avatar_url} name={review.rater.name} isBuyer />
        </section>
      </section>
      {review.response && !isEditing && !hideResponse ? (
        <section style={{ display: "grid", gap: "var(--spacer-2)", marginLeft: "var(--spacer-4)" }}>
          <p style={{ margin: 0 }}>{review.response.message}</p>
          <section style={{ display: "flex", gap: "var(--spacer-1)", alignItems: "center", flexWrap: "wrap" }}>
            {seller ? <ReviewUserAttribution avatarUrl={seller.avatar_url} name={seller.name} /> : null}
            <DateWithTooltip date={review.response.created_at.date} humanized={review.response.created_at.humanized} />
            <span className="pill small">Creator</span>
          </section>
        </section>
      ) : null}
      {canRespond && !hideResponse ? (
        <section style={{ marginLeft: "var(--spacer-4)" }}>
          <ReviewResponseForm
            message={review.response?.message}
            purchaseId={review.purchase_id}
            onChange={(message: string) =>
              setReview((prev) => ({
                ...prev,
                response: {
                  message,
                  created_at: {
                    date: new Date().toISOString(),
                    humanized: "just now",
                  },
                },
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
