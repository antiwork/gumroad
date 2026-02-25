import { FileDetail, Trash, XCircle } from "@boxicons/react";
import cx from "classnames";
import * as React from "react";

import FileUtils from "$app/utils/file";
import { SUBTITLE_LANGUAGES } from "$app/utils/subtitle_languages";
import { summarizeUploadProgress } from "$app/utils/summarizeUploadProgress";

import { Button } from "$app/components/Button";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Row, RowActions, RowContent, RowDetails } from "$app/components/ui/Rows";
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
export const SubtitleRow = ({ subtitleFile, onRemove, onCancel, onChangeLanguage }: Props) => {
  const progress =
    subtitleFile.status.type === "unsaved" && subtitleFile.status.uploadStatus.type === "uploading"
      ? subtitleFile.status.uploadStatus.progress
      : null;

  return (
    <Row className={cx("subtitle-row-container", "subtitle-row", "relative", { complete: !progress })} role="listitem">
      {progress ? (
        <>
          <RowDetails>
            <UploadProgressBar progress={progress.percent} />
          </RowDetails>
          <RowContent>
            <LoadingSpinner className="size-8" />
            <div>
              <h4>{subtitleFile.file_name}</h4>
              {`${summarizeUploadProgress(progress.percent, progress.bitrate, subtitleFile.file_size ?? 0)} ${
                subtitleFile.extension
              }`}
            </div>
          </RowContent>
          <RowActions>
            <Button size="icon" onClick={onCancel} color="danger" outline aria-label="Remove">
              <XCircle pack="filled" className="size-5" />
            </Button>
          </RowActions>
        </>
      ) : (
        <>
          <RowContent>
            <FileDetail pack="filled" className="type-icon size-5" />
            <div>
              <h4>{subtitleFile.file_name}</h4>
              {FileUtils.getFullFileSizeString(subtitleFile.file_size ?? 0)} {subtitleFile.extension}
            </div>
          </RowContent>
          <RowActions>
            <SubtitleLanguageSelect currentLanguage={subtitleFile.language} onChange={onChangeLanguage} />
            <Button size="icon" onClick={onRemove} color="danger" outline aria-label="Remove">
              <Trash className="size-5" />
            </Button>
          </RowActions>
        </>
      )}
    </Row>
  );
};

type SelectProps = { currentLanguage: string; onChange: (newLanguage: string) => void };
const SubtitleLanguageSelect = ({ currentLanguage, onChange }: SelectProps) => (
  <select
    aria-label="Language"
    value={currentLanguage}
    onChange={(evt) => onChange(evt.target.value)}
    className="w-auto"
  >
    {SUBTITLE_LANGUAGES.map((language) => (
      <option key={language} value={language}>
        {language}
      </option>
    ))}
  </select>
);
