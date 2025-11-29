import * as React from "react";

import { Rows } from "$app/components/ui/Rows";

import { SubtitleRow, SubtitleFile } from "./Row";

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
    <Rows role="list">
      {subtitleFiles.map((subtitleFile) => (
        <SubtitleRow
          key={subtitleFile.url}
          subtitleFile={subtitleFile}
          onRemove={() => onRemoveSubtitle(subtitleFile.url)}
          onCancel={() => onCancelSubtitleUpload(subtitleFile.url)}
          onChangeLanguage={(language) => onChangeSubtitleLanguage(subtitleFile.url, language)}
        />
      ))}
    </Rows>
  );
};
