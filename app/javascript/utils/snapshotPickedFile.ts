// Chrome revokes <input type="file"> File backing when the input is reset
// (ERR_BLOB_REFERENCED_FILE_UNAVAILABLE). Copy small files before reset;
// over-limit files keep the original handle, so callers must not reset.

export const PICKED_FILE_SNAPSHOT_LIMIT_BYTES = 512 * 1024 * 1024;

export const canResetFileInputAfterSnapshot = (files: readonly File[]): boolean =>
  files.every((file) => file.size <= PICKED_FILE_SNAPSHOT_LIMIT_BYTES);

export const snapshotPickedFile = async (file: File): Promise<File> => {
  if (file.size > PICKED_FILE_SNAPSHOT_LIMIT_BYTES) return file;
  const buffer = await file.arrayBuffer();
  return new File([buffer], file.name, { type: file.type, lastModified: file.lastModified });
};

export const snapshotPickedFiles = (files: readonly File[]): Promise<File[]> =>
  Promise.all(files.map(snapshotPickedFile));
