import { debounce } from "lodash-es";
import * as React from "react";

import { useRefToLatest } from "./useRefToLatest";

export const useDebouncedCallback = <T extends unknown[]>(cb: (...args: T) => void, delay: number) => {
  const underlyingFnRef = useRefToLatest(cb);

  return React.useMemo(() => {
    const wrapper = (...args: T) => underlyingFnRef.current(...args);
    return debounce(wrapper, delay);
  }, [delay]);
};
