import { useEffect, useState } from "react";

import { getReviewVideoUploadContext, ReviewVideoUploadContext } from "$app/data/product_reviews";
import { assertResponseError } from "$app/utils/request";

import { useLoggedInUser } from "$app/components/LoggedInUser";
import { useConfigureEvaporate } from "$app/components/useConfigureEvaporate";

export const useReviewVideoUploader = () => {
  const loggedInUser = useLoggedInUser();
  const [uploadContext, setUploadContext] = useState<ReviewVideoUploadContext | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!loggedInUser) return;
    let isMounted = true;

    const initializeUploader = async () => {
      try {
        const context = await getReviewVideoUploadContext();
        if (!isMounted) return;

        setUploadContext(context);
      } catch (err) {
        assertResponseError(err);
        setError("Failed to get upload context");
      }
    };

    void initializeUploader();

    return () => {
      isMounted = false;
    };
  }, [loggedInUser]);

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
