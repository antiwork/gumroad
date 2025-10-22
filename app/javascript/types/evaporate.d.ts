declare module "$vendor/evaporate.cjs" {
  type UploadParams = {
    name: string;
    file: File;
    url: string;
    mimeType: string;
    xAmzHeadersAtInitiate: Record<string, string>;
    complete: () => void;
    progress: (this: { file: File; sizeBytes: number }, percent: number) => void;
    initiated: (uploadId: string) => void;
  };

  class Evaporate {
    supported: boolean;

    constructor(params: {
      signerUrl: string;
      aws_key: string;
      bucket: string;
      fetchCurrentServerTimeUrl: string;
      maxFileSize?: number;
      s3Endpoint?: string;
    });

    add(params: UploadParams): string | number;

    cancel(uploadId: string): void;
  }
  export = Evaporate;
}
