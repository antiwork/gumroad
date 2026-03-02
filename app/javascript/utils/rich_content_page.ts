import { FileDetail, Key, MoviePlay, MusicAlt, type BoxIconProps } from "@boxicons/react";

import { FILE_TYPE_EXTENSIONS_MAP } from "$app/utils/file";

export type PageIconType = "license-key" | "text-only" | "video-file" | "music-file" | "mixed-files";

export const PAGE_ICON_COMPONENTS: Record<PageIconType, React.ComponentType<BoxIconProps>> = {
  "license-key": Key,
  "text-only": FileDetail,
  "video-file": MoviePlay,
  "music-file": MusicAlt,
  "mixed-files": FileDetail,
};

export const PAGE_ICON_LABELS: Record<PageIconType, string> = {
  "mixed-files": "Page has various types of files",
  "music-file": "Page has audio files",
  "video-file": "Page has videos",
  "text-only": "Page has no files",
  "license-key": "Page has license key",
};

export const generatePageIcon = ({
  hasLicense,
  fileIds,
  allFiles,
}: {
  hasLicense: boolean;
  fileIds: string[];
  allFiles: { id: string; extension: string | null }[];
}): PageIconType => {
  if (hasLicense) return "license-key";

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
  if (totalFiles === 0) return "text-only";
  if (fileTypeCounts.video > totalFiles / 2) return "video-file";
  if (fileTypeCounts.audio > totalFiles / 2) return "music-file";
  return "mixed-files";
};
