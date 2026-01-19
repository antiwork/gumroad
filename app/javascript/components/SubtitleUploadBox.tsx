import * as React from "react";

import FileUtils from "$app/utils/file";

import { buttonVariants } from "$app/components/Button";
import { showAlert } from "$app/components/server-components/Alert";

type UploadBoxProps = { onUploadFiles: (domFiles: File[]) => void };

const acceptedSubtitleExtensions = FileUtils.getAllowedSubtitleExtensions()
  .map((ext) => `.${ext}`)
  .join(",");

export const SubtitleUploadBox = ({ onUploadFiles }: UploadBoxProps) => {
  const filePickerOnChange = (fileInput: HTMLInputElement) => {
    if (!fileInput.files) return;
    const files = [...fileInput.files];
    if (files.some((file) => !FileUtils.isFileNameASubtitle(file.name))) {
      showAlert("Invalid file type.", "error");
      return;
    }
    fileInput.value = "";
    onUploadFiles(files);
  };

  return (
    <label className={buttonVariants({ size: "default", color: "primary" })}>
      <input
        className="subtitles-file"
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
