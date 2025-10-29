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
  // Extract the S3 endpoint from the s3_url by removing the bucket name
  // e.g., "https://s3.amazonaws.com/my-bucket" -> "https://s3.amazonaws.com"
  // e.g., "http://minio:9000/my-bucket" -> "http://minio:9000"
  const s3Endpoint = props.s3_url.substring(0, props.s3_url.lastIndexOf("/"));

  const cancellationKeysToUploadIdsRef = React.useRef<Record<string, string>>({});

  const evaporate = React.useMemo(
    () =>
      new Evaporate({
        signerUrl: Routes.s3_utility_generate_multipart_signature_path(),
        aws_key: props.aws_access_key_id,
        bucket,
        fetchCurrentServerTimeUrl: Routes.s3_utility_current_utc_time_string_path(),
        maxFileSize: MAX_FILE_SIZE,
        s3Endpoint,
        maxConcurrentParts: 3,
        partSize: 20 * 1024 * 1024,
        retryBackoffPower: 2,
        maxRetryBackoffSecs: 300,
        checkForPreviousUploads: true,
        maxRetries: 5,
        progressIntervalMS: 1000,
        logging: false,
      }),
    [props.aws_access_key_id, bucket, s3Endpoint],
  );

  const s3UploadConfig = React.useMemo(
    () => ({
      generateS3KeyForUpload: (guid: string, name: string) => {
        const s3key = FileUtils.getS3Key(
          guid,
          encodeURIComponent(name).replace("'", "%27"),
          props.user_id,
          ROOT_BUCKET_NAME,
        );
        return {
          s3key,
          fileUrl: `${props.s3_url}/${decodeURIComponent(s3key)}`,
        };
      },
    }),
    [props.s3_url, props.user_id],
  );

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

    const status = evaporate.add({
      name,
      file,
      url: props.s3_url,
      mimeType,
      xAmzHeadersAtInitiate: { "x-amz-acl": "private" },
      complete: () => {
        onComplete();
      },
      progress: (percent: number) => {
        const progressSinceLastIteration = percent - previousProgress;
        previousProgress = percent;

        const progress = {
          percent,
          bitrate: file.size * progressSinceLastIteration,
        };

        onProgress(progress);
      },
      initiated: (uploadId: string) => {
        cancellationKeysToUploadIdsRef.current[cancellationKey] = uploadId;
      },
    });

    return status;
  };

  const cancelUpload = (cancellationKey: string) => {
    const uploadId = cancellationKeysToUploadIdsRef.current[cancellationKey];
    if (uploadId) {
      evaporate.cancel(uploadId);
      const { [cancellationKey]: _, ...rest } = cancellationKeysToUploadIdsRef.current;
      cancellationKeysToUploadIdsRef.current = rest;
    }
  };

  const retryUpload = () => true;

  return {
    evaporateUploader: {
      scheduleUpload,
      cancelUpload,
      retryUpload,
    },
    s3UploadConfig,
  };
};
