import cx from "classnames";
import * as React from "react";

import FileUtils from "$app/utils/file";
import { summarizeUploadProgress } from "$app/utils/summarizeUploadProgress";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Progress } from "$app/components/Progress";
import { UploadProgressBar } from "$app/components/UploadProgressBar";
import { UploadProgress } from "$app/components/useConfigureEvaporate";

export type ChapterFile = {
  file_name: string;
  extension: string;
  title?: string;
  file_size: null | number;
  url: string;
  signed_url: string;
  status:
    | { type: "saved" }
    | { type: "existing" }
    | { type: "unsaved"; uploadStatus: { type: "uploaded" } | { type: "uploading"; progress: UploadProgress } };
};

type Props = {
  chapterFile: ChapterFile;
  onRemove: () => void;
  onCancel: () => void;
};

export const Row = ({ chapterFile, onRemove, onCancel }: Props) => {
  const progress =
    chapterFile.status.type === "unsaved" && chapterFile.status.uploadStatus.type === "uploading"
      ? chapterFile.status.uploadStatus.progress
      : null;

  return (
    <div className={cx("chapter-row-container", "subtitle-row", "relative", { complete: !progress })} role="treeitem">
      {progress ? (
        <>
          <UploadProgressBar progress={progress.percent} />
          <div className="content">
            <Progress width="2em" />
            <div>
              <h4>{chapterFile.file_name}</h4>
              {`${summarizeUploadProgress(progress.percent, progress.bitrate, chapterFile.file_size ?? 0)} ${
                chapterFile.extension
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
              <h4>{chapterFile.file_name}</h4>
              <div className="subtitle">Chapters • {FileUtils.getFullFileSizeString(chapterFile.file_size ?? 0)} {chapterFile.extension}</div>
            </div>
          </div>
          <div className="actions">
            <Button onClick={onRemove} color="danger" outline aria-label="Remove">
              <Icon name="trash2" />
            </Button>
          </div>
        </>
      )}
    </div>
  );
};
