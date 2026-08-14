import * as React from "react";

// Assign during render so layout-time children (Sortable setList) see this
// paint's value. An effect-timed write left ContentTab holding the previous
// variant for one frame and overwrote the newly selected tier's pages.
export const useRefToLatest = <T>(value: T): React.MutableRefObject<T> => {
  const ref = React.useRef(value);
  ref.current = value;
  return ref;
};
