export const humanizedDuration = (durationInSeconds: number): string => {
  // Compute the parts arithmetically. Building a Date and reading getUTCHours()
  // (the previous implementation) wraps at 24, so a 25-hour audio file showed
  // as "1h 0m" and a 24-hour one as "0m 0s" on the download page.
  const hours = Math.floor(durationInSeconds / 3600);
  const minutes = Math.floor((durationInSeconds % 3600) / 60);
  const seconds = Math.floor(durationInSeconds % 60);

  return hours > 0 ? `${hours}h ${minutes}m` : `${minutes}m ${seconds}s`;
};
