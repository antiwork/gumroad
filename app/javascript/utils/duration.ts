export const humanizedDuration = (durationInSeconds: number): string => {
  const milliseconds = durationInSeconds * 1000;
  const date = new Date(milliseconds);
  const hours = date.getUTCHours(),
    minutes = date.getUTCMinutes(),
    seconds = date.getUTCSeconds();

  return hours > 0 ? `${hours}h ${minutes}m` : `${minutes}m ${seconds}s`;
};
