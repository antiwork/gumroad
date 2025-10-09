import { cast } from "ts-safe-cast";

import { last } from "$app/utils/array";

export const ALLOWED_EXTENSIONS = ["jpeg", "jpg", "png", "gif", "webp"];

const FileUtils = {
  getReadableFileSize: (bytes: number): string => {
    if (bytes >= 1073741824) {
      return `${(bytes / 1073741824).toFixed(1)} GB`;
    } else if (bytes >= 1048576) {
      return `${(bytes / 1048576).toFixed(1)} MB`;
    } else if (bytes >= 1024) {
      return `${(bytes / 1024).toFixed(1)} KB`;
    } else if (bytes > 1) {
      return `${bytes.toString()} bytes`;
    } else if (bytes === 1) {
      return `${bytes.toString()} byte`;
    }
    return "0 byte";
  },
  getFullFileSizeString: (bytes: number): string => FileUtils.getReadableFileSize(bytes),
  getS3Key: (guid: string, fileName: string, userExternalId: string, rootBucket: string): string => {
    const prefix = FileUtils.generateS3KeyPrefix(guid, userExternalId, rootBucket);
    return `${prefix}/${fileName}`;
  },
  generateS3KeyPrefix: (guid: string, userExternalId: string, rootBucket: string): string =>
    `${rootBucket}/${userExternalId}/${guid}/original`,
  getGuidBase: (): string => "xxxxxxxxxxxx4xxxyxxxxxxxxxxxxxxx",
  getGuidLength: (): number => FileUtils.getGuidBase().length,
  generateGuid: (): string =>
    // neat hack from http://stackoverflow.com/questions/105034/how-to-create-a-guid-uuid-in-javascript/2117523#2117523
    FileUtils.getGuidBase().replace(/[xy]/gu, (c) => {
      const r = (Math.random() * 16) | 0,
        v = c === "x" ? r : (r & 0x3) | 0x8;
      return v.toString(16);
    }),
  getFileExtension: (name: string): string => {
    // from http://stackoverflow.com/a/680982/2624068
    const match = /(?:\.([^.]+))?$/u.exec(name);
    if (match == null) return "";
    const extension = match[1];
    return extension == null ? "" : extension;
  },
  getFileNameWithoutExtension: (filename: string): string => {
    const extension = FileUtils.getFileExtension(filename).toUpperCase();
    return extension.length > 0 ? filename.slice(0, filename.length - extension.length - 1) : filename;
  },
  getAllowedSubtitleExtensions: (): string[] => ["srt", "vtt"],
  extractUniqueUrlIdentifier: (url: string): string => {
    const guidLength = FileUtils.getGuidLength();
    const guid = url.split("/original/")[0].slice(-1 * guidLength);
    // NOTE: ideally, this shouldn't encode the url identifier
    if (guid && guid.length === guidLength && isAlphanumeric(guid)) {
      return guid;
    }
    return encodeURIComponent(url);
  },
  determineS3BucketForForm: ($form: JQuery) => {
    const s3Url: string = cast($form[0]?.dataset.s3Url);
    return last(s3Url.split("/"));
  },
  determineAWSAccessKeyIdForForm: ($form: JQuery) => cast<string>($form[0]?.dataset.awsAccessKeyId),
  determineUserExternalIdForForm: ($form: JQuery) => cast<string>($form[0]?.dataset.userExternalId),
  isFileExtensionStreamable: (extension: string) => {
    const streamableExtensions = ["mp4", "m4v", "mov", "mpeg", "mpeg4", "wmv", "movie", "ogv", "avi", "webm"];
    return streamableExtensions.includes(extension.toLowerCase());
  },
  isAudioExtension: (extension: string | null) =>
    extension !== null && FILE_TYPE_EXTENSIONS_MAP.audio.includes(extension),
  isDocumentExtension: (extension: string | null) =>
    extension !== null && FILE_TYPE_EXTENSIONS_MAP.document.includes(extension),
  isFileNameStreamable: (fileName: string) => {
    const ext = FileUtils.getFileExtension(fileName);
    return FileUtils.isFileExtensionStreamable(ext);
  },
  isFileExtensionASubtitle: (ext: string) => FileUtils.getAllowedSubtitleExtensions().includes(ext.toLowerCase()),
  isFileNameASubtitle: (fileName: string) => {
    const ext = FileUtils.getFileExtension(fileName);
    return FileUtils.isFileExtensionASubtitle(ext);
  },
  isFileNameExtensionAllowed: (filename: string, allowedExtensions: string[]) => {
    const ext = FileUtils.getFileExtension(filename).toLowerCase();
    return allowedExtensions.some((item) => item.toLowerCase() === ext);
  },
};

const isAlphanumeric = (text: string) => /^[a-zA-Z0-9]+$/u.test(text);

export const FILE_TYPE_EXTENSIONS_MAP = {
  image: ["JPG", "JPEG", "PNG", "GIF", "SVG"],
  audio: ["MP3", "WAV", "FLAC", "WMA", "AAC", "M4A"],
  video: ["MP4", "MOV", "WMV", "AVI", "MKV", "WEBM", "FLV"],
  document: ["PDF", "EPUB", "MOBI"],
  zip: ["RAR", "ZIP"],
};

export default FileUtils;
