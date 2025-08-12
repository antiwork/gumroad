import * as React from "react";

import { Row, ChapterFile } from "./Row";

type Props = {
  chapterFile: ChapterFile | null;
  onRemoveChapter: () => void;
  onCancelChapterUpload: () => void;
};

export const ChapterList = ({
  chapterFile,
  onRemoveChapter,
  onCancelChapterUpload,
}: Props) => {
  if (!chapterFile) return null;

  return (
    <div className="chapter-list" role="tree">
      <Row
        key={chapterFile.url}
        chapterFile={chapterFile}
        onRemove={onRemoveChapter}
        onCancel={onCancelChapterUpload}
      />
    </div>
  );
};
