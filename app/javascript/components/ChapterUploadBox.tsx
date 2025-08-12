import * as React from "react";

import FileUtils from "$app/utils/file";

import { showAlert } from "$app/components/server-components/Alert";

type UploadBoxProps = { onUploadFiles: (domFiles: File[]) => void };

const acceptedChapterExtensions = FileUtils.getAllowedChapterExtensions()
  .map((ext) => `.${ext}`)
  .join(",");

export const ChapterUploadBox = ({ onUploadFiles }: UploadBoxProps) => {
  const filePickerOnChange = (fileInput: HTMLInputElement) => {
    if (!fileInput.files) return;
    const files = [...fileInput.files];
    if (files.some((file) => !FileUtils.isFileNameAChapter(file.name))) {
      showAlert("Invalid file type. Please upload a WebVTT (.vtt) chapter file.", "error");
      return;
    }
    if (files.length > 1) {
      showAlert("Only one chapter file is allowed per video.", "error");
      return;
    }
    fileInput.value = "";
    onUploadFiles(files);
  };

  return (
    <label className="button primary">
      <input
        className="chapters-file"
        type="file"
        name="file"
        accept={acceptedChapterExtensions}
        tabIndex={-1}
        onChange={(e) => filePickerOnChange(e.target)}
      />
      Add chapters
    </label>
  );
};
