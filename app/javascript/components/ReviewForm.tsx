import { DirectUpload } from "@rails/activestorage";
import * as React from "react";

import { setProductRating } from "$app/data/product_reviews";
import { assertDefined } from "$app/utils/assert";
import FileUtils from "$app/utils/file";
import { assertResponseError } from "$app/utils/request";
import { summarizeUploadProgress } from "$app/utils/summarizeUploadProgress";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { RatingSelector } from "$app/components/RatingSelector";
import { useReviewVideoUploader } from "$app/components/ReviewForm/useReviewVideoUploader";
import { VideoReview } from "$app/components/ReviewForm/VideoReview";
import { showAlert } from "$app/components/server-components/Alert";

export type Review = {
  rating: number;
  message: string | null;
  video: {
    id: string;
    thumbnail_url: string | null;
  } | null;
};

type VideoState =
  | { kind: "none" }
  | { kind: "existing"; id: string; thumbnailUrl: string | null }
  | { kind: "recorded"; file: File; url: string }
  | { kind: "deleted"; id: string };

const uploadThumbnail = (thumbnail: File): Promise<string> => {
  if (thumbnail.size > 5 * 1024 * 1024) {
    throw new Error("Could not process your thumbnail, please upload an image with size smaller than 5 MB.");
  }

  const upload = new DirectUpload(thumbnail, Routes.rails_direct_uploads_path());

  return new Promise((resolve, reject) => {
    upload.create((error, blob) => {
      if (error) {
        reject(error);
      } else {
        resolve(blob.signed_id);
      }
    });
  });
};

const generateThumbnail = (videoFile: File): Promise<File | undefined> =>
  new Promise((resolve) => {
    const video = document.createElement("video");
    const videoSrc = URL.createObjectURL(videoFile);
    video.src = videoSrc;
    video.crossOrigin = "anonymous";

    // Delay to work around a bug in Safari which otherwise captures a
    // black/empty thumbnail.
    video.addEventListener("loadedmetadata", () => setTimeout(() => (video.currentTime = 1), 100));

    const canvas = document.createElement("canvas");
    video.addEventListener("seeked", () => {
      canvas.width = video.videoWidth;
      canvas.height = video.videoHeight;

      const ctx = assertDefined(canvas.getContext("2d"));
      ctx.drawImage(video, 0, 0, canvas.width, canvas.height);

      canvas.toBlob(
        (blob) => {
          if (blob) {
            const file = new File([blob], "thumbnail.jpg");
            resolve(file);
          } else {
            resolve(undefined);
          }

          URL.revokeObjectURL(videoSrc);
          video.remove();
          canvas.remove();
        },
        "image/jpeg",
        0.5,
      );
    });
  });

const gracefullyGenerateAndUploadThumbnail = async (videoFile: File): Promise<string | undefined> => {
  try {
    const thumbnail = await generateThumbnail(videoFile);
    if (thumbnail) {
      return await uploadThumbnail(thumbnail);
    }
  } catch (_) {}

  return undefined;
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
    const video = React.useRef<{ id: string; thumbnail_url: string | null } | File | null>(null);
    const [uploadProgress, setUploadProgress] = React.useState<{ percent: number; bitrate: number } | null>(null);
    const [uploadCancellationKey, setUploadCancellationKey] = React.useState<string | null>(null);

    const loggedInUser = useLoggedInUser();
    const { error, readyToUpload, evaporateUploader, s3UploadConfig } = useReviewVideoUploader();

    const uid = React.useId();
    const viewing = formState === "viewing";
    const disabled = isLoading || preview || !!disabledStatus;
    const readyToSubmit = reviewMode === "text" || readyToUpload;

    const cancelUpload = () => {
      if (uploadCancellationKey && evaporateUploader) {
        evaporateUploader.cancelUpload(uploadCancellationKey);
        setUploadCancellationKey(null);
        setUploadProgress(null);
        setIsLoading(false);
      }
    };

    const uploadVideo = async (videoFile: File): Promise<string> => {
      if (!s3UploadConfig || !evaporateUploader) {
        throw new Error("Upload configuration not ready");
      }

      setIsLoading(true);

      const id = FileUtils.generateGuid();
      const cancellationKey = `cancel-video-review-upload-${id}`;
      setUploadCancellationKey(cancellationKey);

      return new Promise((resolve, reject) => {
        const { s3key, fileUrl } = s3UploadConfig.generateS3KeyForUpload(id, videoFile.name);

        const status = evaporateUploader.scheduleUpload({
          cancellationKey,
          name: s3key,
          file: videoFile,
          mimeType: videoFile.type,
          onComplete: () => {
            setUploadProgress(null);
            setUploadCancellationKey(null);
            resolve(fileUrl);
          },
          onProgress: setUploadProgress,
        });

        if (typeof status === "number" && isNaN(status)) {
          setIsLoading(false);
          setUploadCancellationKey(null);
          reject(new Error("Failed to schedule upload"));
        }
      });
    };

    const generateVideoOptions = async () => {
      if (video.current === null && review?.video?.id) {
        return { destroy: { id: review.video.id } };
      }

      if (video.current instanceof File) {
        try {
          const fileUrl = await uploadVideo(video.current);
          const thumbnailSignedId = await gracefullyGenerateAndUploadThumbnail(video.current);
          return { create: { url: fileUrl, thumbnail_signed_id: thumbnailSignedId } };
        } catch (error) {
          setIsLoading(false);
          throw error;
        }
      }

      return {};
    };

    const generateReviewContentPayload = async () => {
      switch (reviewMode) {
        case "text":
          return { message: message || null };
        case "video":
          return { videoOptions: await generateVideoOptions() };
      }
    };

    const handleSubmit = async (event: React.FormEvent<HTMLFormElement>) => {
      event.preventDefault();
      if (preview || !rating) return;

      setIsLoading(true);

      try {
        const content = await generateReviewContentPayload();

        const review = await setProductRating({
          permalink,
          purchaseId,
          purchaseEmailDigest: purchaseEmailDigest ?? "",
          rating,
          ...content,
        });
        setFormState("viewing");
        onChange?.(review);
        video.current = review.video?.id ?? null;
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

    const uploadProgressDisplay = uploadProgress && (
      <div className="bg-gray-100 mt-2 flex w-full items-center justify-between rounded px-3 py-2">
        <div>
          {summarizeUploadProgress(
            uploadProgress.percent,
            uploadProgress.bitrate,
            video.current instanceof File ? video.current.size : 0,
          )}
        </div>
        <Button onClick={cancelUpload} type="button" className="ml-2 !py-1">
          <Icon name="x" className="text-sm" /> Cancel
        </Button>
      </div>
    );

    const videoReview = loggedInUser ? (
      <>
        <VideoReview
          formState={formState}
          videoUrl={null}
          onVideoChange={(newVideo) => {
            if (newVideo instanceof File) {
              video.current = newVideo;
            } else {
              video.current = null;
            }
          }}
          disabled={disabled}
        />
        {uploadProgressDisplay}
      </>
    ) : (
      <div>
        <a href={Routes.login_path()}>Log in</a> or <a href={Routes.signup_path()}>create an account</a> using the same
        email address as your purchase to upload a video review.
      </div>
    );

    const reviewButton = viewing ? (
      <Button onClick={() => setFormState("editing")} key="edit" type="button">
        Edit
      </Button>
    ) : (
      <Button color="primary" disabled={disabled || rating === null || !readyToSubmit} key="submit" type="submit">
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
        {error ? (
          <div role="status" className="error mb-2">
            {error}
          </div>
        ) : null}
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
