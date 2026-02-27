import { FileDetail, Key, MusicAlt, Play, type BoxIconProps } from "@boxicons/react";

import { FILE_TYPE_EXTENSIONS_MAP } from "$app/utils/file";

export type PageIconKey = "outline-key" | "file-text" | "file-play" | "file-music" | "file-arrow-down";

export const PAGE_ICON_COMPONENTS: Record<PageIconKey, React.ComponentType<BoxIconProps>> = {
  "outline-key": Key,
  "file-text": FileDetail,
  "file-play": Play,
  "file-music": MusicAlt,
  "file-arrow-down": FileDetail,
};

export const generatePageIcon = ({
  hasLicense,
  fileIds,
  allFiles,
}: {
  hasLicense: boolean;
  fileIds: string[];
  allFiles: { id: string; extension: string | null }[];
}): PageIconKey => {
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
  if (totalFiles === 0) return "file-text";
  if (fileTypeCounts.video > totalFiles / 2) return "file-play";
  if (fileTypeCounts.audio > totalFiles / 2) return "file-music";
  return "file-arrow-down";
};
