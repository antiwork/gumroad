import cx from "classnames";
import * as React from "react";

import FileUtils from "$app/utils/file";
import { SUBTITLE_LANGUAGES } from "$app/utils/subtitle_languages";
import { summarizeUploadProgress } from "$app/utils/summarizeUploadProgress";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { UploadProgressBar } from "$app/components/UploadProgressBar";
import { UploadProgress } from "$app/components/useConfigureEvaporate";

export type SubtitleFile = {
  file_name: string;
  extension: string;
  language: string;
  file_size: null | number;
  url: string;
  signed_url: string;
  status:
    | { type: "saved" }
    | { type: "existing" }
    | { type: "unsaved"; uploadStatus: { type: "uploaded" } | { type: "uploading"; progress: UploadProgress } };
};

type Props = {
  subtitleFile: SubtitleFile;
  onRemove: () => void;
  onCancel: () => void;
  onChangeLanguage: (newLanguage: string) => void;
};
export const Row = ({ subtitleFile, onRemove, onCancel, onChangeLanguage }: Props) => {
  const progress =
    subtitleFile.status.type === "unsaved" && subtitleFile.status.uploadStatus.type === "uploading"
      ? subtitleFile.status.uploadStatus.progress
      : null;

  return (
    <div className={cx("subtitle-row-container", "subtitle-row", "relative", { complete: !progress })} role="treeitem">
      {progress ? (
        <>
          <UploadProgressBar progress={progress.percent} />
          <div className="content">
            <LoadingSpinner className="size-8" />
            <div>
              <h4>{subtitleFile.file_name}</h4>
              {`${summarizeUploadProgress(progress.percent, progress.bitrate, subtitleFile.file_size ?? 0)} ${
                subtitleFile.extension
              }`}
            </div>
          </div>
          <div className="actions">
            <Button onClick={onCancel} color="danger" outline aria-label="Remove">
              <Icon name="x-circle-fill" />
            </Button>
          </div>
        </>
      ) : (
        <>
          <div className="content">
            <Icon name="solid-document-text" className="type-icon" />
            <div>
              <h4>{subtitleFile.file_name}</h4>
              {FileUtils.getFullFileSizeString(subtitleFile.file_size ?? 0)} {subtitleFile.extension}
            </div>
          </div>
          <div className="actions">
            <SubtitleLanguageSelect currentLanguage={subtitleFile.language} onChange={onChangeLanguage} />
            <Button onClick={onRemove} color="danger" outline aria-label="Remove">
              <Icon name="trash2" />
            </Button>
          </div>
        </>
      )}
    </div>
  );
};

type SelectProps = { currentLanguage: string; onChange: (newLanguage: string) => void };
const SubtitleLanguageSelect = ({ currentLanguage, onChange }: SelectProps) => (
  <select aria-label="Language" value={currentLanguage} onChange={(evt) => onChange(evt.target.value)}>
    {SUBTITLE_LANGUAGES.map((language) => (
      <option key={language} value={language}>
        {language}
      </option>
    ))}
  </select>
);
