import * as React from "react";

import { setProductRating } from "$app/data/product_reviews";
import { assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { RatingSelector } from "$app/components/RatingSelector";
import { VideoReview } from "$app/components/ReviewForm/VideoReview";
import { showAlert } from "$app/components/server-components/Alert";

export type Review = {
  rating: number;
  message: string | null;
};

export const ReviewForm = React.forwardRef<
  HTMLTextAreaElement,
  {
    permalink: string;
    purchaseId: string;
    purchaseEmailDigest?: string;
    review: Review | null;
    videoReviewsEnabled: boolean;
    onChange?: (review: Review) => void;
    preview?: boolean;
    disabledStatus?: string | null;
    style?: React.CSSProperties;
  }
>(
  (
    {
      permalink,
      purchaseId,
      purchaseEmailDigest,
      review,
      videoReviewsEnabled,
      onChange,
      preview,
      disabledStatus,
      style,
    },
    ref,
  ) => {
    const [isLoading, setIsLoading] = React.useState(false);
    const [rating, setRating] = React.useState<number | null>(review?.rating ?? null);
    const [message, setMessage] = React.useState(review?.message ?? "");
    const [reviewMode, setReviewMode] = React.useState<"text" | "video">("text");
    const [formState, setFormState] = React.useState<"viewing" | "editing">(review ? "viewing" : "editing");

    const uid = React.useId();
    const disabled = isLoading || preview || !!disabledStatus;
    const viewing = formState === "viewing";

    const handleSubmit = async (event: React.FormEvent<HTMLFormElement>) => {
      event.preventDefault();
      if (preview || !rating) return;

      setIsLoading(true);
      try {
        await setProductRating({
          permalink,
          purchaseId,
          purchaseEmailDigest: purchaseEmailDigest ?? "",
          rating,
          message: message || null,
        });
        setFormState("viewing");
        onChange?.({ rating, message });
        showAlert("Review submitted successfully!", "success");
      } catch (error) {
        assertResponseError(error);
        showAlert(error.message, "error");
      }
      setIsLoading(false);
    };

    const reviewModeRadioButtons = (
      <div role="radiogroup" className="radio-buttons !grid-cols-2">
        <Button
          role="radio"
          aria-checked={reviewMode === "text"}
          onClick={() => setReviewMode("text")}
          disabled={disabled}
        >
          <div className="w-full text-center">Text review</div>
        </Button>
        <Button
          role="radio"
          aria-checked={reviewMode === "video"}
          onClick={() => setReviewMode("video")}
          disabled={disabled}
        >
          <div className="w-full text-center">Video review</div>
        </Button>
      </div>
    );

    const textReview = viewing ? (
      <div className="w-full">{message ? `"${message}"` : "No written review"}</div>
    ) : (
      <textarea
        id={uid}
        value={message}
        onChange={(evt) => setMessage(evt.target.value)}
        placeholder="Want to leave a written review?"
        disabled={disabled}
        ref={ref}
      />
    );

    const videoReview = <VideoReview formState={formState} videoUrl={null} />;

    const reviewButton = viewing ? (
      <Button onClick={() => setFormState("editing")} key="edit" type="button">
        Edit
      </Button>
    ) : (
      <Button color="primary" disabled={disabled || rating === null} key="submit" type="submit">
        {review ? "Update review" : "Post review"}
      </Button>
    );

    const disabledStatusWarning = disabledStatus && (
      <div role="status" className="warning">
        {disabledStatus}
      </div>
    );

    return (
      <form onSubmit={(event) => void handleSubmit(event)} style={style} className="flex flex-col !items-start">
        <div className="flex flex-wrap justify-between gap-2">
          <label htmlFor={uid}>{viewing ? "Your rating:" : "Liked it? Give it a rating:"}</label>
          <RatingSelector currentRating={rating} onChangeCurrentRating={setRating} disabled={disabled || viewing} />
        </div>

        {!viewing && videoReviewsEnabled ? reviewModeRadioButtons : null}
        {reviewMode === "video" && videoReviewsEnabled ? videoReview : textReview}
        {disabledStatusWarning}
        {reviewButton}
      </form>
    );
  },
);

ReviewForm.displayName = "ReviewForm";
