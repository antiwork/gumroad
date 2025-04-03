import * as React from "react";

export type S3UploadConfig = {
  generateS3KeyForUpload: (guid: string, name: string) => { s3key: string; fileUrl: string };
};
type ContextValue = S3UploadConfig;

const Context = React.createContext<ContextValue | null>(null);

export const S3UploadConfigProvider = Context.Provider;

export const useS3UploadConfig = (): S3UploadConfig => {
  const value = React.useContext(Context);

  if (value == null) {
    throw new Error("Cannot read S3 upload config, make sure S3UploadConfig is used higher up in the tree");
  }

  return value;
};
