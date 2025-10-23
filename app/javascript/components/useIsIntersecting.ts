import * as React from "react";

import { useRefToLatest } from "$app/components/useRefToLatest";

export const useIsIntersecting = <T extends HTMLElement = HTMLElement>(
  callback: (isIntersecting: boolean) => void,
  options?: IntersectionObserverInit,
) => {
  const elementRef = React.useRef<T>(null);
  const callbackRef = useRefToLatest(callback);

  React.useEffect(() => {
    if (!elementRef.current) return;

    const observer = new IntersectionObserver((entries) => {
      const isIntersecting = entries.some((entry) => entry.isIntersecting);
      callbackRef.current(isIntersecting);
    }, options);

    observer.observe(elementRef.current);
    return () => observer.disconnect();
  }, [options]);

  return elementRef;
};
