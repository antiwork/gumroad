import * as React from "react";

type Props = {
  progress: number; // between 0.0 and 1.0
};
export const UploadProgressBar = ({ progress }: Props) => (
  <div className="uploading-bar" style={{ width: `${progress * 100}%` }} />
);
