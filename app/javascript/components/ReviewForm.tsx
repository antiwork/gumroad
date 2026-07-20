import { DirectUpload } from "@rails/activestorage";
import * as React from "react";

import { setProductRating } from "$app/data/product_reviews";
import { assertDefined } from "$app/utils/assert";
import FileUtils from "$app/utils/file";
import { assertResponseError } from "$app/utils/request";
import { summarizeUploadProgress } from "$app/utils/summarizeUploadProgress";

import { Button } from "$app/components/Button";
import { useAppDomain } from "$app/components/DomainSettings";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { RatingSelector } from "$app/components/RatingSelector";
import { ReviewVideoRecorder } from "$app/components/ReviewForm/ReviewVideoRecorder";
import { ReviewVideoRecorderUiState, VideoState } from "$app/components/ReviewForm/ReviewVideoRecorderCommon";
import { useReviewVideoUploader } from "$app/components/ReviewForm/useReviewVideoUploader";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";
import { Label } from "$app/components/ui/Label";
import { Tab, Tabs } from "$app/components/ui/Tabs";
import { Textarea } from "$app/components/ui/Textarea";

export type Review = {
  rating: number;
  message: string | null;
  video: {
    id: string;
    thumbnail_url: string | null;
  } | null;
};

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
    onChange?: (review: Review) => void;
    preview?: boolean;
    disabledStatus?: string | null;
    style?: React.CSSProperties;
    className?: string;
  }
>(
  (
    { permalink, purchaseId, purchaseEmailDigest, review, onChange, preview, disabledStatus, style, className },
    ref,
  ) => {
    const appDomain = useAppDomain();
    const [isLoading, setIsLoading] = React.useState(false);
    const [rating, setRating] = React.useState<number | null>(review?.rating ?? null);
    const [message, setMessage] = React.useState(review?.message ?? "");
    const [reviewMode, setReviewMode] = React.useState<"text" | "video">(review?.video ? "video" : "text");
    const [formState, setFormState] = React.useState<"viewing" | "editing">(review ? "viewing" : "editing");
    const [videoState, setVideoState] = React.useState<VideoState>(
      review?.video
        ? { kind: "existing", id: review.video.id, thumbnailUrl: review.video.thumbnail_url }
        : { kind: "none" },
    );
    const [uploadProgress, setUploadProgress] = React.useState<{ percent: number; bitrate: number } | null>(null);
    const [uploadCancellationKey, setUploadCancellationKey] = React.useState<string | null>(null);
    const [videoRecorderUiState, setVideoRecorderUiState] = React.useState<ReviewVideoRecorderUiState | null>(null);

    const loggedInUser = useLoggedInUser();
    const { error, readyToUpload, evaporateUploader, s3UploadConfig } = useReviewVideoUploader();

    // Autosave bookkeeping: a monotonically increasing sequence number lets us
    // ignore responses from superseded autosaves (e.g. the buyer taps 3 stars,
    // then 5 stars right after — only the latest save should show a toast), the
    // timeout ref holds the pending debounced save so an explicit submit can
    // cancel it, and the in-flight ref serializes saves: the next autosave (or
    // an explicit submit) waits for a save that already left, so responses
    // can't reach the server out of order and overwrite a newer rating.
    const autosaveSequence = React.useRef(0);
    const autosaveTimeout = React.useRef<ReturnType<typeof setTimeout> | null>(null);
    const autosaveInFlight = React.useRef<Promise<void> | null>(null);

    // Internal handle on the message textarea so we can focus it after a star
    // tap. The component also forwards a ref to the same element for callers
    // (e.g. the Reviews page focuses the next form after a submission), so the
    // two are merged in a callback ref below.
    const messageInputRef = React.useRef<HTMLTextAreaElement | null>(null);
    React.useEffect(
      () => () => {
        if (autosaveTimeout.current) clearTimeout(autosaveTimeout.current);
      },
      [],
    );

    const uid = React.useId();
    const viewing = formState === "viewing";
    const disabled = isLoading || preview || !!disabledStatus;
    const reviewVideoRecorderBusy = videoRecorderUiState !== null && videoRecorderUiState !== "idle";
    const readyToSubmit = rating && (reviewMode === "text" || (readyToUpload && !reviewVideoRecorderBusy));

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
      if (videoState.kind === "deleted") {
        return { destroy: { id: videoState.id } };
      }

      if (videoState.kind === "recorded") {
        try {
          const fileUrl = await uploadVideo(videoState.file);
          const thumbnailSignedId = await gracefullyGenerateAndUploadThumbnail(videoState.file);
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

    // A rating alone is a valid review, so save it the moment a star is tapped
    // instead of making the buyer find the separate "Post review" button (which
    // can sit below the fold on mobile — buyers tapped stars, saw nothing
    // happen, and gave up). The save is debounced so tapping around the stars
    // fires one request, and the form stays open afterwards so the buyer can
    // still add the written or video review as a follow-up.
    const autosaveRating = (newRating: number) => {
      if (preview || disabled || viewing) return;

      if (autosaveTimeout.current) clearTimeout(autosaveTimeout.current);
      const sequence = (autosaveSequence.current += 1);

      autosaveTimeout.current = setTimeout(() => {
        autosaveTimeout.current = null;

        // Serialize autosaves: each save waits for the one that already left
        // before sending. setProductRating is a plain PUT with no sequence
        // field, so if two saves raced the server could apply them out of
        // order and a slow earlier response would overwrite the buyer's final
        // rating. Chaining guarantees the latest tap is also the last write.
        const previous = autosaveInFlight.current;

        const save = (async () => {
          if (previous) await previous.catch(() => undefined);
          // While waiting for the previous save, this one may have been
          // superseded by a newer tap or an explicit submit — skip sending a
          // now-stale rating entirely.
          if (sequence !== autosaveSequence.current) return;

          try {
            // Only the rating (and whatever message is already in the box) is
            // autosaved — video uploads stay behind the explicit submit.
            await setProductRating({
              permalink,
              purchaseId,
              purchaseEmailDigest: purchaseEmailDigest ?? "",
              rating: newRating,
              message: message || null,
            });
            if (sequence !== autosaveSequence.current) return;
            showAlert(message ? "Rating saved!" : "Rating saved! Add a written review to tell others more.", "success");
          } catch (error) {
            if (sequence !== autosaveSequence.current) return;
            assertResponseError(error);
            showAlert(error.message, "error");
          }
        })();

        autosaveInFlight.current = save;
        void save.finally(() => {
          if (autosaveInFlight.current === save) autosaveInFlight.current = null;
        });
      }, 500);
    };

    const handleSubmit = async (event: React.FormEvent<HTMLFormElement>) => {
      event.preventDefault();
      if (preview || !rating) return;

      // An explicit submit supersedes any pending or in-flight rating autosave:
      // drop the debounced save, bump the sequence so a late autosave response
      // can't show a stale toast, and wait for a request that already left so
      // the server applies this submission last.
      if (autosaveTimeout.current) {
        clearTimeout(autosaveTimeout.current);
        autosaveTimeout.current = null;
      }
      autosaveSequence.current += 1;

      setIsLoading(true);

      try {
        if (autosaveInFlight.current) await autosaveInFlight.current;
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

        setVideoState(
          review.video
            ? { kind: "existing", id: review.video.id, thumbnailUrl: review.video.thumbnail_url }
            : { kind: "none" },
        );
        setMessage(review.message ?? "");
        setReviewMode(review.video ? "video" : "text");

        showAlert("Review submitted successfully!", "success");
      } catch (error) {
        assertResponseError(error);
        showAlert(error.message, "error");
      }
      setIsLoading(false);
    };

    const reviewModeRadioButtons = (
      <Tabs variant="buttons" className="grid-cols-2!" role="radiogroup">
        <Tab isSelected={reviewMode === "text"} asChild>
          <Button
            role="radio"
            aria-checked={reviewMode === "text"}
            onClick={() => setReviewMode("text")}
            disabled={disabled || reviewVideoRecorderBusy}
            className="disabled:pointer-events-none"
          >
            <div className="w-full text-center">Text review</div>
          </Button>
        </Tab>
        <Tab isSelected={reviewMode === "video"} asChild>
          <Button
            role="radio"
            aria-checked={reviewMode === "video"}
            onClick={() => setReviewMode("video")}
            disabled={disabled || reviewVideoRecorderBusy}
            className="disabled:pointer-events-none"
          >
            <div className="w-full text-center">Video review</div>
          </Button>
        </Tab>
      </Tabs>
    );

    const textReview = viewing ? (
      <div className="w-full">{message ? `"${message}"` : "No written review"}</div>
    ) : (
      <Textarea
        id={uid}
        value={message}
        onChange={(evt) => setMessage(evt.target.value)}
        placeholder="Want to leave a written review?"
        disabled={disabled}
        ref={(element) => {
          // Merge our internal ref (used to focus the textarea after a star
          // tap) with the forwarded ref callers pass in.
          messageInputRef.current = element;
          if (typeof ref === "function") ref(element);
          else if (ref) ref.current = element;
        }}
      />
    );

    const uploadProgressDisplay = uploadProgress ? (
      <div>
        {summarizeUploadProgress(
          uploadProgress.percent,
          uploadProgress.bitrate,
          videoState.kind === "recorded" ? videoState.file.size : 0,
        )}{" "}
        -{" "}
        <button onClick={cancelUpload} type="button" className="cursor-pointer underline all-unset">
          Cancel
        </button>
      </div>
    ) : null;

    const videoReview = loggedInUser ? (
      <>
        <ReviewVideoRecorder
          formState={formState}
          videoState={videoState}
          onVideoChange={(newVideoState) => {
            setVideoState(newVideoState);
          }}
          onUiStateChange={setVideoRecorderUiState}
          disabled={disabled}
        />
        {uploadProgressDisplay}
      </>
    ) : (
      <div>
        <a href={Routes.login_url({ host: appDomain })}>Log in</a> or{" "}
        <a href={Routes.signup_url({ host: appDomain })}>create an account</a> using the same email address as your
        purchase to upload a video review.
      </div>
    );

    const reviewButton = viewing ? (
      disabled ? null : (
        <Button onClick={() => setFormState("editing")} key="edit" type="button">
          Edit
        </Button>
      )
    ) : (
      <Button color="primary" disabled={disabled || !readyToSubmit} key="submit" type="submit">
        {review ? "Update review" : "Post review"}
      </Button>
    );

    const disabledStatusWarning = disabledStatus && (
      <Alert role="status" variant="warning">
        {disabledStatus}
      </Alert>
    );

    return (
      <form
        onSubmit={(event) => void handleSubmit(event)}
        style={style}
        className={`flex flex-col items-start! ${className}`}
      >
        {error ? <p className="text-red"> {error} </p> : null}
        <div className="flex grow flex-wrap items-center justify-between gap-2">
          <Label htmlFor={uid}>{viewing ? "Your rating:" : "Liked it? Give it a rating:"}</Label>
          <RatingSelector
            currentRating={rating}
            onChangeCurrentRating={(newRating) => {
              setRating(newRating);
              autosaveRating(newRating);
              // Move the buyer straight into the written review: focus the
              // textarea (which also scrolls it into view when it sits below
              // the fold). The rating is already autosaved at this point, so
              // typing is purely an optional next step — nothing is lost if
              // they stop here. Only applies in text mode; the video recorder
              // has no text input to focus.
              if (reviewMode === "text") messageInputRef.current?.focus();
            }}
            disabled={disabled || viewing}
          />
        </div>

        {!viewing ? reviewModeRadioButtons : null}
        {reviewMode === "video" ? videoReview : textReview}
        {disabledStatusWarning}
        {reviewButton}
      </form>
    );
  },
);

ReviewForm.displayName = "ReviewForm";
