// Wraps an async function so overlapping calls share one in-flight invocation instead of each
// firing their own. Built for save() in the product editor (gumroad-private#1962): a burst of
// Preview clicks before React re-renders the disabled state could POST several concurrent saves,
// and for a still-unreconciled `newlyAdded` version each save creates its own server-side variant.
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
