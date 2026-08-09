// Wraps an async function so overlapping calls share one in-flight invocation instead of each
// firing their own request.
export const dedupeInFlight = <T>(fn: () => Promise<T>): (() => Promise<T>) => {
  let inFlight: Promise<T> | null = null;
  return () => {
    if (inFlight) return inFlight;
    const promise = fn().finally(() => {
      if (inFlight === promise) inFlight = null;
    });
    inFlight = promise;
    return promise;
  };
};
