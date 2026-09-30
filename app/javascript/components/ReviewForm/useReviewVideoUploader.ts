import { useEffect, useRef, useState } from "react";

import { getReviewVideoUploadContext, ReviewVideoUploadContext } from "$app/data/product_reviews";
import { assertResponseError } from "$app/utils/request";

import { useLoggedInUser } from "$app/components/LoggedInUser";
import { useConfigureEvaporate } from "$app/components/useConfigureEvaporate";

// `enabled` keeps the context request lazy: the context is only needed once the buyer is editing a
// video review, but every form used to fetch it on mount (Reviews/Index mounts one per purchase
// awaiting review).
export const useReviewVideoUploader = ({ enabled, preview }: { enabled: boolean; preview?: boolean }) => {
  // The id, not the user object: the layouts call parseLoggedInUser inline, so every render of one,
  // including each usePoll reload on the download page, hands down a new object and re-ran the effect.
  // The id is still tracked, so a context loaded for another user is never reused.
  const loggedInUserId = useLoggedInUser()?.id;
  const [loaded, setLoaded] = useState<Record<string, ReviewVideoUploadContext>>({});
  const [failedUserId, setFailedUserId] = useState<string | null>(null);
  const pendingRequest = useRef<{ userId: string; promise: Promise<ReviewVideoUploadContext> } | null>(null);
  const uploadContext = loggedInUserId != null ? (loaded[loggedInUserId] ?? null) : null;
  const shouldFetch = enabled && !preview && loggedInUserId != null && uploadContext == null;
  // Bound to the request that failed: shown only while enabled and for the same user, since the form
  // renders it in text mode too, where a video request failure is not relevant.
  const error =
    enabled && failedUserId != null && failedUserId === loggedInUserId ? "Failed to get upload context" : null;

  useEffect(() => {
    if (!shouldFetch || loggedInUserId == null) return;
    let isMounted = true;

    // A retry is under way, so the previous attempt's failure no longer describes the form.
    setFailedUserId(null);

    // Shared so that toggling out of video mode and back while the request is in flight does not send a second one.
    const requestContext = () => {
      if (pendingRequest.current?.userId === loggedInUserId) return pendingRequest.current.promise;
      const promise = getReviewVideoUploadContext().finally(() => {
        if (pendingRequest.current?.promise === promise) pendingRequest.current = null;
      });
      pendingRequest.current = { userId: loggedInUserId, promise };
      return promise;
    };

    const initializeUploader = async () => {
      try {
        const context = await requestContext();
        // Kept even if the request was cancelled meanwhile: it is stored under its user id, so only that
        // user can use it, and discarding it would make leaving and re-entering video mode refetch.
        setLoaded((current) => ({ ...current, [loggedInUserId]: context }));
      } catch (err) {
        assertResponseError(err);
        if (!isMounted) return;
        setFailedUserId(loggedInUserId);
      }
    };

    void initializeUploader();

    return () => {
      isMounted = false;
    };
  }, [shouldFetch, loggedInUserId]);

  const { evaporateUploader, s3UploadConfig } = useConfigureEvaporate({
    aws_access_key_id: uploadContext?.aws_access_key_id ?? "",
    s3_url: uploadContext?.s3_url ?? "",
    user_id: uploadContext?.user_id ?? "",
  });

  const readyToUpload = uploadContext != null;

  return {
    error,
    readyToUpload,
    evaporateUploader: readyToUpload ? evaporateUploader : null,
    s3UploadConfig: readyToUpload ? s3UploadConfig : null,
  };
};
