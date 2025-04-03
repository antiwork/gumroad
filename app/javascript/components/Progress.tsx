import * as React from "react";

declare module "react" {
  export interface CSSProperties {
    "--progress"?: number | string;
  }
}

export const Progress = ({
  progress,
  width,
  ...props
}: {
  progress?: number;
  width?: string;
  "aria-label"?: string;
}) =>
  progress !== undefined ? (
    <div
      role="progressbar"
      style={{ "--progress": progress.toFixed(4), width }}
      aria-valuenow={Math.round(progress * 10000) / 100}
      {...props}
    />
  ) : (
    <div role="progressbar" style={{ width }} {...props} />
  );
