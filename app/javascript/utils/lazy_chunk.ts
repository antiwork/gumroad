// Network failures are removed from the browser's module map, so the same import can recover when
// tried again. React.lazy does not make that retry itself: once the promise it receives rejects, it
// remembers the rejection. Complete one retry before giving React the final promise.
const RETRY_DELAY_MS = 500;

export const fetchWithOneRetry = async <T>(fetch: () => Promise<T>, delayMs = RETRY_DELAY_MS): Promise<T> => {
  try {
    return await fetch();
  } catch (firstError) {
    await new Promise((resolve) => setTimeout(resolve, delayMs));
    try {
      return await fetch();
    } catch {
      // Report the first failure because it happened under normal conditions; the second attempt
      // was a recovery probe and can obscure the original cause.
      throw firstError;
    }
  }
};
