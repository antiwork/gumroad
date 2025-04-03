import * as React from "react";

export const useHasTimeoutPassedAfterValueChanged = (value: unknown, timeoutMs: number): boolean => {
  const [hasTimeoutPassed, setHasTimeoutPassed] = React.useState(false);

  React.useEffect(() => {
    setHasTimeoutPassed(false);
    const timeout = setTimeout(() => {
      setHasTimeoutPassed(true);
    }, timeoutMs);

    return () => {
      clearTimeout(timeout);
    };
  }, [value]);

  return hasTimeoutPassed;
};
