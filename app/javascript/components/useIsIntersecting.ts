import * as React from "react";

export const useIsIntersecting = <T extends HTMLElement = HTMLElement>(
  callback: (isIntersecting: boolean) => void,
  options?: IntersectionObserverInit,
) => {
  const elementRef = React.useRef<T>(null);

  React.useEffect(() => {
    if (!elementRef.current) return;

    const observer = new IntersectionObserver((entries) => {
      const isIntersecting = entries.some((entry) => entry.isIntersecting);
      callback(isIntersecting);
    }, options);

    observer.observe(elementRef.current);
    return () => observer.disconnect();
  }, [options, callback]);

  return elementRef;
};
