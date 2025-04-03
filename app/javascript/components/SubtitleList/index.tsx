import * as React from "react";

import { Row, SubtitleFile } from "./Row";

type Props = {
  subtitleFiles: SubtitleFile[];
  onRemoveSubtitle: (url: string) => void;
  onCancelSubtitleUpload: (url: string) => void;
  onChangeSubtitleLanguage: (url: string, newLanguage: string) => void;
};
export const SubtitleList = ({
  subtitleFiles,
  onRemoveSubtitle,
  onCancelSubtitleUpload,
  onChangeSubtitleLanguage,
}: Props) => {
  if (subtitleFiles.length === 0) return null;

  return (
    <div className="subtitle-list" role="tree">
      {subtitleFiles.map((subtitleFile) => (
        <Row
          key={subtitleFile.url}
          subtitleFile={subtitleFile}
          onRemove={() => onRemoveSubtitle(subtitleFile.url)}
          onCancel={() => onCancelSubtitleUpload(subtitleFile.url)}
          onChangeLanguage={(language) => onChangeSubtitleLanguage(subtitleFile.url, language)}
        />
      ))}
    </div>
  );
};
