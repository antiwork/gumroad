import Evaporate from "$vendor/evaporate.cjs";
import * as React from "react";

import { last } from "$app/utils/array";
import FileUtils from "$app/utils/file";

const ROOT_BUCKET_NAME = "attachments";
const MAX_FILE_SIZE = 20 * 1024 * 1024 * 1024; // 20 GB

export type UploadProgress = { percent: number; bitrate: number };

type Props = { aws_access_key_id: string; s3_url: string; user_id: string };
export const useConfigureEvaporate = (props: Props) => {
  const bucket = last(props.s3_url.split("/"));
  const evaporateRef = React.useRef(
    new Evaporate({
      signerUrl: Routes.s3_utility_generate_multipart_signature_path(),
      aws_key: props.aws_access_key_id,
      bucket,
      fetchCurrentServerTimeUrl: Routes.s3_utility_current_utc_time_string_path(),
      maxFileSize: MAX_FILE_SIZE,
    }),
  );

  const s3UploadConfig = {
    generateS3KeyForUpload: (guid: string, name: string) => {
      const s3key = FileUtils.getS3Key(
        guid,
        // Firefox does not handle the encoding of ' characters correctly, we have to force it to work here
        encodeURIComponent(name).replace("'", "%27"),
        props.user_id,
        ROOT_BUCKET_NAME,
      );
      return { s3key, fileUrl: `${props.s3_url}/${decodeURIComponent(s3key)}` };
    },
  };

  const cancellationKeysToUploadIdsRef = React.useRef<Record<string, string>>({});
  const scheduleUpload = ({
    cancellationKey,
    name,
    file,
    mimeType,
    onComplete,
    onProgress,
  }: {
    cancellationKey: string;
    name: string;
    file: File;
    mimeType: string;
    onComplete: () => void;
    onProgress: (progress: UploadProgress) => void;
  }) => {
    let previousProgress = 0;

    const status = evaporateRef.current.add({
      name,
      file,
      url: props.s3_url,
      mimeType,
      xAmzHeadersAtInitiate: { "x-amz-acl": "private" },
      complete: onComplete,
      progress(percent) {
        // Calculate the bitrate of the file upload by subtracting the completed percentage from the last iteration from the current iteration percentage
        // and multiplying that by the bytesize.  I have found this to be accurate enough by comparing my upload
        // speed to the speed reported by this method.
        const progressSinceLastIteration = percent - previousProgress;

        previousProgress = percent;

        const progress = { percent, bitrate: this.sizeBytes * progressSinceLastIteration };

        onProgress(progress);
      },
      initiated: (uploadId) => {
        // initiated is called immediately before the uploader starts the upload of a file,
        // the uploadId here is needed for cancelling uploads (cancelling uploads requires an uploadId)
        cancellationKeysToUploadIdsRef.current[cancellationKey] = uploadId;
      },
    });

    if (typeof status === "number" && isNaN(status)) {
      return status;
    }

    return status;
  };

  const cancelUpload = (cancellationKey: string) => {
    const uploadId = cancellationKeysToUploadIdsRef.current[cancellationKey];
    if (uploadId) evaporateRef.current.cancel(uploadId);
  };

  return { evaporateUploader: { scheduleUpload, cancelUpload }, s3UploadConfig };
};
