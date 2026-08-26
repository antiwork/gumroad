import * as React from "react";

import FileUtils from "$app/utils/file";
import {
  canResetFileInputAfterSnapshot,
  fileListMatchesPickedFiles,
  snapshotPickedFiles,
} from "$app/utils/snapshotPickedFile";

import { buttonVariants } from "$app/components/Button";
import { showAlert } from "$app/components/server-components/Alert";

type UploadBoxProps = { onUploadFiles: (domFiles: File[]) => void };

const acceptedSubtitleExtensions = FileUtils.getAllowedSubtitleExtensions()
  .map((ext) => `.${ext}`)
  .join(",");

export const SubtitleUploadBox = ({ onUploadFiles }: UploadBoxProps) => {
  const filePickerOnChange = (fileInput: HTMLInputElement) => {
    if (!fileInput.files) return;
    const picked = [...fileInput.files];
    if (picked.some((file) => !FileUtils.isFileNameASubtitle(file.name))) {
      showAlert("Invalid file type.", "error");
      return;
    }
    void snapshotPickedFiles(picked)
      .then((files) => {
        onUploadFiles(files);
        if (fileListMatchesPickedFiles(fileInput.files, picked) && canResetFileInputAfterSnapshot(picked, files))
          fileInput.value = "";
      })
      .catch((error: unknown) => {
        showAlert(error instanceof Error ? error.message : "Could not read the selected file.", "error");
      });
  };

  return (
    <label className={buttonVariants({ size: "default", color: "primary" })}>
      <input
        className="subtitles-file sr-only"
        type="file"
        name="file"
        accept={acceptedSubtitleExtensions}
        tabIndex={-1}
        multiple
        onChange={(e) => filePickerOnChange(e.target)}
      />
      Add subtitles
    </label>
  );
};
