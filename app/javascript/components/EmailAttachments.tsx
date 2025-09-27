import * as React from "react";

import FileUtils from "$app/utils/file";
import { getMimeType } from "$app/utils/mimetypes";
import { summarizeUploadProgress } from "$app/utils/summarizeUploadProgress";

import { Button } from "$app/components/Button";
import { useEvaporateUploader } from "$app/components/EvaporateUploader";
import { FileRowContent } from "$app/components/FileRowContent";
import { Icon } from "$app/components/Icons";
import { useS3UploadConfig } from "$app/components/S3UploadConfig";
import { showAlert } from "$app/components/server-components/Alert";
import { Drawer } from "$app/components/SortableList";
import { SubtitleList } from "$app/components/SubtitleList";
import { SubtitleFile } from "$app/components/SubtitleList/Row";
import { SubtitleUploadBox } from "$app/components/SubtitleUploadBox";
import { Toggle } from "$app/components/Toggle";
import { UploadProgress } from "$app/components/useConfigureEvaporate";
import { WithTooltip } from "$app/components/WithTooltip";

export type FileItem = {
  id: string;
  file_name: string;
  description: string | null;
  extension: string;
  file_size: number | null;
  is_pdf: boolean;
  pdf_stamp_enabled: boolean;
  is_streamable: boolean;
  stream_only: boolean;
  is_transcoding_in_progress: boolean;
  url: string;
  subtitle_files: SubtitleFile[];
  thumbnail: { url: string; signed_id: string } | null;
};

type FileStatus =
  | { type: "saved" }
  | { type: "existing" }
  | {
      type: "unsaved";
      uploadStatus: { type: "uploaded" } | { type: "uploading"; progress: UploadProgress };
    };

type SubtitleFileState = SubtitleFile & { status: FileStatus };

export type FileState = Omit<FileItem, "subtitle_files"> & {
  email_id: string;
  subtitle_files: SubtitleFileState[];
  status: FileStatus;
};

const FilesContext = React.createContext<null | FileState[]>(null);
export const FilesProvider = FilesContext.Provider;

export const useFiles = (selectorFn?: (files: FileState[]) => FileState[]) => {
  const files = React.useContext(FilesContext);
  if (files === null) throw new Error("useFiles must be used within a FilesProvider");
  return selectorFn ? selectorFn(files) : files;
};

const FilesDispatchContext = React.createContext<null | React.Dispatch<FileAction>>(null);
export const FilesDispatchProvider = FilesDispatchContext.Provider;

const useFilesDispatch = () => {
  const dispatch = React.useContext(FilesDispatchContext);
  if (dispatch === null) throw new Error("useFilesDispatch must be used within a FilesDispatchProvider");
  return dispatch;
};

export const mapEmailFilesToFileState = (files: FileItem[], emailId: string): FileState[] =>
  files.map((file) => ({
    email_id: emailId,
    ...file,
    status: { type: "existing" },
    subtitle_files: file.subtitle_files.map((subtitle) => ({
      ...subtitle,
      status: { type: "existing" },
    })),
  }));

export const isFileUploading = (file: FileState | SubtitleFileState) =>
  file.status.type === "unsaved" && file.status.uploadStatus.type === "uploading";

const uploadingFileCancellationKey = (fileId: string) => `file_${fileId}`;
const uploadingSubtitleFileCancellationKey = (fileId: string, subtitleUrl: string) =>
  `subtitles_for_${fileId}__${subtitleUrl}`;

export const FileRow = ({ file }: { file: FileState }) => {
  const [isDrawerOpen, setIsDrawerOpen] = React.useState(false);
  const uploader = useEvaporateUploader();
  const filesDispatch = useFilesDispatch();
  const uploadSubtitles = useUploadSubtitles();
  const uploadProgress =
    file.status.type === "unsaved" && file.status.uploadStatus.type === "uploading"
      ? file.status.uploadStatus.progress
      : null;

  return (
    <div role="listitem">
      <div className="content">
        <FileRowContent
          name={file.file_name}
          extension={file.extension}
          externalLinkUrl={file.url}
          isUploading={uploadProgress !== null}
          details={
            <>
              {file.file_size !== null ? (
                <li>
                  {uploadProgress === null
                    ? FileUtils.getFullFileSizeString(file.file_size)
                    : summarizeUploadProgress(uploadProgress.percent, uploadProgress.bitrate, file.file_size)}
                </li>
              ) : null}
              {file.extension ? <li>{file.extension}</li> : null}
            </>
          }
        />
      </div>
      <div className="actions">
        {file.is_streamable ? (
          <Button onClick={() => setIsDrawerOpen(!isDrawerOpen)} aria-label="Edit">
            <Icon name="pencil" />
          </Button>
        ) : null}
        <WithTooltip tip={uploadProgress === null ? "Remove" : "Cancel"} position="left">
          <Button
            outline
            color="danger"
            aria-label="Remove"
            onClick={() => {
              if (uploadProgress !== null) uploader?.cancelUpload(uploadingFileCancellationKey(file.id));
              filesDispatch({ type: "remove-file", fileId: file.id });
            }}
          >
            <Icon name="trash2" />
          </Button>
        </WithTooltip>
      </div>
      {isDrawerOpen ? (
        <Drawer>
          {file.is_streamable ? (
            <div className="grid gap-3">
              <SubtitleList
                subtitleFiles={file.subtitle_files}
                onRemoveSubtitle={(subtitleUrl) =>
                  filesDispatch({ type: "remove-subtitle", fileId: file.id, subtitleUrl })
                }
                onCancelSubtitleUpload={(subtitleUrl) => {
                  uploader?.cancelUpload(uploadingSubtitleFileCancellationKey(file.id, subtitleUrl));
                  filesDispatch({ type: "remove-subtitle", fileId: file.id, subtitleUrl });
                }}
                onChangeSubtitleLanguage={(subtitleUrl, language) =>
                  filesDispatch({ type: "change-subtitle-language", fileId: file.id, subtitleUrl, language })
                }
              />
              <SubtitleUploadBox
                onUploadFiles={(subtitleFiles) => {
                  if (uploadSubtitles) {
                    uploadSubtitles(file.id, subtitleFiles);
                  } else {
                    showAlert(
                      "Unfortunately, file uploads aren't supported in your browser. Please update to the latest version and try again.",
                      "error",
                    );
                  }
                }}
              />
            </div>
          ) : null}
        </Drawer>
      ) : null}
    </div>
  );
};

export const EmailAttachments = ({
  emailId,
  isStreamOnly,
  setIsStreamOnly,
}: {
  emailId: string;
  isStreamOnly: boolean;
  setIsStreamOnly: (val: boolean) => void;
}) => {
  const files = useFiles((files) => files.filter(({ email_id }) => email_id === emailId));
  const hasStreamableFiles = files.some((file) => file.is_streamable);
  const uploadFiles = useUploadFiles();
  const onAttachFiles = (fileInput: HTMLInputElement) => {
    if (!fileInput.files) return;
    const files = [...fileInput.files];
    fileInput.value = "";
    if (uploadFiles) {
      uploadFiles(emailId, files);
    } else {
      showAlert(
        "Unfortunately, file uploads aren't supported in your browser. Please update to the latest version and try again.",
        "error",
      );
    }
  };
  return (
    <>
      {files.length > 0 ? (
        <div role="list" className="rows" aria-label="Files">
          {files.map((file) => (
            <FileRow key={file.id} file={file} />
          ))}
        </div>
      ) : null}
      <label className="button primary">
        <input type="file" name="file" tabIndex={-1} multiple onChange={(e) => onAttachFiles(e.target)} />
        <Icon name="paperclip" />
        Attach files
      </label>
      {hasStreamableFiles ? (
        <Toggle value={isStreamOnly} onChange={setIsStreamOnly}>
          Disable file downloads (stream only)
          <a href="/help/article/43-streaming-videos" target="_blank" rel="noreferrer">
            Learn more
          </a>
        </Toggle>
      ) : null}
    </>
  );
};

export const useUploadFiles = (): null | ((emailId: string, files: File[]) => void) => {
  const s3UploadConfig = useS3UploadConfig();
  const filesDispatch = useFilesDispatch();
  const uploader = useEvaporateUploader();
  if (!uploader) return null;
  const inProgressFileEntry = (emailId: string, file: File): { fileEntry: FileState; s3key: string } => {
    const originalName = file.name;
    const extension = FileUtils.getFileExtension(originalName).toUpperCase();
    const isPdf = extension === "PDF";
    const fileName = FileUtils.getFileNameWithoutExtension(originalName);
    const fileSize = file.size;
    const isStreamable = FileUtils.isFileExtensionStreamable(extension);
    const id = FileUtils.generateGuid();
    const { s3key, fileUrl } = s3UploadConfig.generateS3KeyForUpload(id, originalName);
    return {
      s3key,
      fileEntry: {
        id,
        file_name: fileName,
        description: null,
        email_id: emailId,
        extension,
        file_size: fileSize,
        is_streamable: isStreamable,
        is_pdf: isPdf,
        pdf_stamp_enabled: false,
        stream_only: false,
        is_transcoding_in_progress: false,
        thumbnail: null,
        url: fileUrl,
        subtitle_files: [],
        status: {
          type: "unsaved",
          uploadStatus: { type: "uploading", progress: { percent: 0, bitrate: 0 } },
        },
      },
    };
  };

  return (emailId: string, files: File[]) => {
    files.forEach((file) => {
      const originalName = file.name;
      const mimeType = getMimeType(originalName);
      const { fileEntry, s3key } = inProgressFileEntry(emailId, file);
      const id = fileEntry.id;
      filesDispatch({ type: "start-file-upload", file: fileEntry });
      const status = uploader.scheduleUpload({
        cancellationKey: uploadingFileCancellationKey(id),
        name: s3key,
        file,
        mimeType,
        onComplete: () => filesDispatch({ type: "finish-file-upload", fileId: id }),
        onProgress: (progress) => filesDispatch({ type: "set-file-upload-progress", fileId: id, progress }),
      });

      if (typeof status === "string") {
        // status contains error string if any, otherwise index of file in array
        showAlert(status, "error");
      }
    });
  };
};

export const useUploadSubtitles = () => {
  const s3UploadConfig = useS3UploadConfig();
  const filesDispatch = useFilesDispatch();
  const uploader = useEvaporateUploader();
  if (!uploader) return null;

  const inProgressSubtitleEntry = (file: File): { subtitleEntry: SubtitleFileState; s3key: string } => {
    const originalName = file.name;
    const extension = FileUtils.getFileExtension(originalName).toUpperCase();
    const fileName = FileUtils.getFileNameWithoutExtension(originalName);
    const fileSize = file.size;
    const id = FileUtils.generateGuid();
    const { s3key, fileUrl } = s3UploadConfig.generateS3KeyForUpload(id, originalName);
    return {
      s3key,
      subtitleEntry: {
        file_name: fileName,
        extension,
        language: "English",
        file_size: fileSize,
        url: fileUrl,
        signed_url: URL.createObjectURL(file),
        status: { type: "unsaved", uploadStatus: { type: "uploading", progress: { percent: 0, bitrate: 0 } } },
      },
    };
  };

  return (fileId: string, subtitleFiles: File[]) => {
    subtitleFiles.forEach((file) => {
      const originalName = file.name;
      const mimeType = getMimeType(originalName);
      const { subtitleEntry, s3key } = inProgressSubtitleEntry(file);
      filesDispatch({ type: "start-subtitle-upload", fileId, subtitleFile: subtitleEntry });
      const status = uploader.scheduleUpload({
        cancellationKey: uploadingSubtitleFileCancellationKey(fileId, subtitleEntry.url),
        name: s3key,
        file,
        mimeType,
        onComplete: () => filesDispatch({ type: "finish-subtitle-upload", fileId, subtitleUrl: subtitleEntry.url }),
        onProgress: (progress) =>
          filesDispatch({ type: "set-subtitle-upload-progress", fileId, subtitleUrl: subtitleEntry.url, progress }),
      });

      if (typeof status === "string") {
        // status contains error string if any, otherwise index of file in array
        showAlert(status, "error");
      }
    });
  };
};

export type FileAction =
  | { type: "start-file-upload"; file: FileState }
  | { type: "set-file-upload-progress"; fileId: string; progress: UploadProgress }
  | { type: "finish-file-upload"; fileId: string }
  | { type: "remove-file"; fileId: string }
  | { type: "start-subtitle-upload"; fileId: string; subtitleFile: SubtitleFileState }
  | { type: "set-subtitle-upload-progress"; fileId: string; subtitleUrl: string; progress: UploadProgress }
  | { type: "finish-subtitle-upload"; fileId: string; subtitleUrl: string }
  | { type: "remove-subtitle"; fileId: string; subtitleUrl: string }
  | { type: "change-subtitle-language"; fileId: string; subtitleUrl: string; language: string }
  | { type: "reset"; files: FileState[] };

export const filesReducer = (state: FileState[], action: FileAction): FileState[] => {
  const { type } = action;
  switch (type) {
    case "start-file-upload": {
      const { file } = action;
      return [...state, file];
    }
    case "set-file-upload-progress": {
      const { fileId, progress } = action;
      return state.map((file) => {
        if (file.id !== fileId) return file;
        return {
          ...file,
          status: {
            type: "unsaved",
            uploadStatus: {
              type: "uploading",
              progress,
            },
          },
        };
      });
    }
    case "finish-file-upload": {
      const { fileId } = action;
      return state.map((file) => {
        if (file.id !== fileId) return file;
        return {
          ...file,
          status: {
            type: "unsaved",
            uploadStatus: { type: "uploaded" },
          },
        };
      });
    }
    case "remove-file": {
      return state.filter((file) => file.id !== action.fileId);
    }
    case "start-subtitle-upload": {
      const { fileId, subtitleFile } = action;
      return state.map((file) => {
        if (file.id !== fileId) return file;
        return {
          ...file,
          subtitle_files: [...file.subtitle_files, subtitleFile],
        };
      });
    }
    case "set-subtitle-upload-progress": {
      const { fileId, subtitleUrl, progress } = action;
      return state.map((file) => {
        if (file.id !== fileId) return file;
        return {
          ...file,
          subtitle_files: file.subtitle_files.map((subtitle) => {
            if (subtitle.url !== subtitleUrl) return subtitle;
            return {
              ...subtitle,
              status: {
                type: "unsaved",
                uploadStatus: {
                  type: "uploading",
                  progress,
                },
              },
            };
          }),
        };
      });
    }
    case "finish-subtitle-upload": {
      const { fileId, subtitleUrl } = action;
      return state.map((file) => {
        if (file.id !== fileId) return file;
        return {
          ...file,
          subtitle_files: file.subtitle_files.map((subtitle) => {
            if (subtitle.url !== subtitleUrl) return subtitle;
            return {
              ...subtitle,
              status: {
                type: "unsaved",
                uploadStatus: { type: "uploaded" },
              },
            };
          }),
        };
      });
    }
    case "remove-subtitle": {
      const { fileId, subtitleUrl } = action;
      return state.map((file) => {
        if (file.id !== fileId) return file;
        return {
          ...file,
          subtitle_files: file.subtitle_files.filter((subtitle) => subtitle.url !== subtitleUrl),
        };
      });
    }
    case "change-subtitle-language": {
      const { fileId, subtitleUrl, language } = action;
      return state.map((file) => {
        if (file.id !== fileId) return file;
        return {
          ...file,
          subtitle_files: file.subtitle_files.map((subtitle) => {
            if (subtitle.url !== subtitleUrl) return subtitle;
            return {
              ...subtitle,
              language,
            };
          }),
        };
      });
    }
    case "reset": {
      return action.files;
    }
  }
};
