import { useEffect, useState } from "react";

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
  const [loaded, setLoaded] = useState<{ userId: string; context: ReviewVideoUploadContext } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const uploadContext = loaded != null && loaded.userId === loggedInUserId ? loaded.context : null;
  const shouldFetch = enabled && !preview && loggedInUserId != null && uploadContext == null;

  useEffect(() => {
    if (!shouldFetch || loggedInUserId == null) return;
    let isMounted = true;

    const initializeUploader = async () => {
      try {
        const context = await getReviewVideoUploadContext();
        if (!isMounted) return;

        setError(null);
        setLoaded({ userId: loggedInUserId, context });
      } catch (err) {
        assertResponseError(err);
        if (!isMounted) return;
        setError("Failed to get upload context");
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
