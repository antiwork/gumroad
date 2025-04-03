import { FILE_TYPE_EXTENSIONS_MAP } from "$app/utils/file";

export const generatePageIcon = ({
  hasLicense,
  fileIds,
  allFiles,
}: {
  hasLicense: boolean;
  fileIds: string[];
  allFiles: { id: string; extension: string | null }[];
}) => {
  if (hasLicense) return "outline-key";

  const fileTypeCounts = { video: 0, audio: 0, unknown: 0 };
  for (const fileId of fileIds) {
    const fileEntry = allFiles.find((file) => file.id === fileId);
    if (!fileEntry) continue;
    if (fileEntry.extension === null) {
      fileTypeCounts.unknown += 1;
    } else if (FILE_TYPE_EXTENSIONS_MAP.video.includes(fileEntry.extension)) {
      fileTypeCounts.video += 1;
    } else if (FILE_TYPE_EXTENSIONS_MAP.audio.includes(fileEntry.extension)) {
      fileTypeCounts.audio += 1;
    } else {
      fileTypeCounts.unknown += 1;
    }
  }

  const totalFiles = fileIds.length;
  let pageType: IconName;
  if (totalFiles === 0) {
    pageType = "file-text";
  } else if (fileTypeCounts.video > totalFiles / 2) {
    pageType = "file-play";
  } else if (fileTypeCounts.audio > totalFiles / 2) {
    pageType = "file-music";
  } else {
    pageType = "file-arrow-down";
  }
  return pageType;
};
