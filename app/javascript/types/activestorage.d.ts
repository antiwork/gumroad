declare module "@rails/activestorage" {
  // Adopted from https://github.com/DefinitelyTyped/DefinitelyTyped/blob/master/types/activestorage/index.d.ts

  export class DirectUpload {
    id: number;
    file: File;
    url: string;

    constructor(file: File, url: string, delegate?: DirectUploadDelegate);
    create(callback: (error: Error | null, blob: Blob) => void): void;
  }

  export interface DirectUploadDelegate {
    directUploadWillCreateBlobWithXHR?: (xhr: XMLHttpRequest) => void;
    directUploadWillStoreFileWithXHR?: (xhr: XMLHttpRequest) => void;
  }

  export interface Blob {
    byte_size: number;
    checksum: string;
    content_type: string;
    filename: string;
    signed_id: string;

    key: string;
  }
}
