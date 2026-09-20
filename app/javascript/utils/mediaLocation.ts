export const NEAR_END_SECONDS = 30;
export const NEAR_END_FRACTION = 0.05;

// Cap at 30s and 5% so a long session that stopped in the tail restarts, while a
// short file paused mid-track is still resumable.
export const nearEndToleranceSeconds = (contentLength: number): number =>
  Math.min(NEAR_END_SECONDS, contentLength * NEAR_END_FRACTION);

export const isFinishedMediaLocation = (
  location: number | null | undefined,
  contentLength: number | null | undefined,
): boolean => {
  if (location == null || contentLength == null || contentLength <= 0) return false;
  return location >= contentLength - nearEndToleranceSeconds(contentLength);
};

export const isResumableMediaLocation = (
  location: number | null | undefined,
  contentLength: number | null | undefined,
): location is number => !!location && !isFinishedMediaLocation(location, contentLength);

export const persistableMediaLocation = (position: number, contentLength: number | null | undefined): number => {
  if (contentLength == null || contentLength <= 0) return position;
  if (isFinishedMediaLocation(position, contentLength) || position > contentLength) return contentLength;
  return position;
};
