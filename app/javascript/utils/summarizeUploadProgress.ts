import FileUtils from "$app/utils/file";

export const summarizeUploadProgress = (progress: number, bitrate: number, fileSize: number) => {
  const formattedPercent = `${(progress * 100).toFixed(0)}%`;
  const formattedFileSize = FileUtils.getFullFileSizeString(fileSize);
  const formattedBitrate = `${FileUtils.getReadableFileSize(bitrate)}/second`;

  return `${formattedPercent} of ${formattedFileSize} (${formattedBitrate})`;
};
