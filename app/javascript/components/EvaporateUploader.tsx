import * as React from "react";

export type EvaporateUploader = {
  scheduleUpload: (options: {
    cancellationKey: string;
    name: string;
    file: File;
    mimeType: string;
    onComplete: () => void;
    onProgress: (progress: { percent: number; bitrate: number }) => void;
  }) => string | number;
  cancelUpload: (cancellationKey: string) => void;
};
// `null` indicates Evaporate is not supported
type ContextValue = null | EvaporateUploader;

const Context = React.createContext<ContextValue>(null);

export const EvaporateUploaderProvider = Context.Provider;

export const useEvaporateUploader = (): ContextValue => {
  const value = React.useContext(Context);
  return value;
};

export const useIsEvaporateSupported = (): boolean => useEvaporateUploader() != null;
