import * as React from "react";

// Holds `value` still until it has stopped changing for `delayMs`, so an expensive consumer — a
// parsed product preview, a chart — runs once per pause instead of once per keystroke. The value
// itself is still stored immediately by the caller; only this read is delayed.
export const useDebouncedValue = <T>(value: T, delayMs: number): T => {
  const [debounced, setDebounced] = React.useState(value);

  React.useEffect(() => {
    const timeout = setTimeout(() => setDebounced(value), delayMs);
    return () => clearTimeout(timeout);
  }, [value, delayMs]);

  return debounced;
};
