import * as React from "react";

// Use to stash the latest `value` into a ref.
// Useful to update hook consumer-supplied event handler without tearing down and setting up a new event listener.
export const useRefToLatest = <T>(value: T): React.MutableRefObject<T> => {
  const ref = React.useRef(value);
  React.useEffect(() => {
    ref.current = value;
  }, [value]);
  return ref;
};
