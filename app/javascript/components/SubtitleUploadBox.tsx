import * as React from "react";

import FileUtils from "$app/utils/file";
import {
  canResetFileInputAfterSnapshot,
  fileListMatchesPickedFiles,
  snapshotPickedFiles,
} from "$app/utils/snapshotPickedFile";

import { buttonVariants } from "$app/components/Button";
import { showAlert } from "$app/components/server-components/Alert";

type UploadBoxProps = { onUploadFiles: (domFiles: File[]) => void | Promise<unknown> };

const acceptedSubtitleExtensions = FileUtils.getAllowedSubtitleExtensions()
  .map((ext) => `.${ext}`)
  .join(",");

export const SubtitleUploadBox = ({ onUploadFiles }: UploadBoxProps) => {
  const snapshotInFlight = React.useRef(false);

  const filePickerOnChange = (fileInput: HTMLInputElement) => {
    if (snapshotInFlight.current || !fileInput.files) return;
    const picked = [...fileInput.files];
    if (picked.some((file) => !FileUtils.isFileNameASubtitle(file.name))) {
      showAlert("Invalid file type.", "error");
      return;
    }
    snapshotInFlight.current = true;
    fileInput.disabled = true;
    void snapshotPickedFiles(picked)
      .then(async (files) => {
        const uploaded = onUploadFiles(files);
        const snapshotted =
          fileListMatchesPickedFiles(fileInput.files, picked) && canResetFileInputAfterSnapshot(picked, files);
        if (snapshotted) fileInput.value = "";
        // Over-budget picks keep the original File. Wait for the caller to finish
        // with that handle (upload complete/cancel) before re-enabling or resetting.
        if (!snapshotted && uploaded && typeof uploaded === "object" && "then" in uploaded) {
          await uploaded;
          if (fileListMatchesPickedFiles(fileInput.files, picked)) fileInput.value = "";
        }
      })
      .catch((error: unknown) => {
        showAlert(error instanceof Error ? error.message : "Could not read the selected file.", "error");
      })
      .finally(() => {
        snapshotInFlight.current = false;
        fileInput.disabled = false;
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
