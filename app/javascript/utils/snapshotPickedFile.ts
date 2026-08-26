// Chrome revokes <input type="file"> File backing when the input is reset
// (ERR_BLOB_REFERENCED_FILE_UNAVAILABLE). Copy small files before reset;
// over-limit files keep the original handle, so callers must not reset.

export const PICKED_FILE_SNAPSHOT_LIMIT_BYTES = 512 * 1024 * 1024;

export const snapshotPickedFile = async (file: File): Promise<File> => {
  if (file.size > PICKED_FILE_SNAPSHOT_LIMIT_BYTES) return file;
  const buffer = await file.arrayBuffer();
  return new File([buffer], file.name, { type: file.type, lastModified: file.lastModified });
};

export const snapshotPickedFiles = async (files: readonly File[]): Promise<File[]> => {
  const out: File[] = [];
  let remaining = PICKED_FILE_SNAPSHOT_LIMIT_BYTES;
  for (const file of files) {
    if (file.size > remaining) {
      out.push(file);
      remaining = 0;
      continue;
    }
    out.push(await snapshotPickedFile(file));
    remaining -= file.size;
  }
  return out;
};

export const canResetFileInputAfterSnapshot = (original: readonly File[], snapshotted: readonly File[]): boolean =>
  original.length === snapshotted.length && original.every((file, i) => file !== snapshotted[i]);

export const fileListMatchesPickedFiles = (
  fileList: Pick<FileList, "length" | "item"> | null,
  files: readonly File[],
): boolean =>
  fileList != null && fileList.length === files.length && files.every((file, index) => fileList.item(index) === file);
