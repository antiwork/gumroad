import { Blob, DirectUpload } from "@rails/activestorage";

// `DirectUpload` gives up on the first failure and, in its store-file step, calls back with a plain
// string (`Error storing "cover.png". Status: 0`) rather than an Error — so `error.message` reads as
// `undefined` and the seller sees an alert with no cause. Retry once before discarding the file the
// seller just picked, then report what actually failed.
const DEFAULT_ATTEMPTS = 2;

const FALLBACK_MESSAGE = "Could not upload your image. Please try again.";

export const uploadErrorMessage = (error: unknown): string => {
  if (typeof error === "string" && error.trim() !== "") return error;
  if (error instanceof Error && error.message !== "") return error.message;
  return FALLBACK_MESSAGE;
};

const uploadOnce = (file: File, url: string): Promise<Blob> =>
  new Promise((resolve, reject) => {
    new DirectUpload(file, url).create((error, blob) => {
      if (error) reject(error);
      else resolve(blob);
    });
  });

export const uploadFileWithRetry = async (file: File, url: string, attempts = DEFAULT_ATTEMPTS): Promise<Blob> => {
  const total = Math.max(1, attempts);
  let lastError: unknown = null;
  for (let attempt = 1; attempt <= total; attempt += 1) {
    try {
      return await uploadOnce(file, url);
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError;
};
