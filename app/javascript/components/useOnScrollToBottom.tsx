import * as React from "react";

import { useRefToLatest } from "$app/components/useRefToLatest";

export const useOnScrollToBottom = (
  ref: React.MutableRefObject<HTMLElement | null>,
  cb: () => void,
  threshold?: number,
) => {
  const cbRef = useRefToLatest(cb);
  React.useEffect(() => {
    if (!ref.current) return;
    let el: HTMLElement | null = ref.current;
    while (el && getComputedStyle(el).overflow !== "auto") el = el.parentElement;
    const scrollContainer = el ?? document.body;
    const scrollListener = () => {
      if (scrollContainer.scrollTop + scrollContainer.offsetHeight > scrollContainer.scrollHeight - (threshold ?? 0))
        cbRef.current();
    };
    scrollListener();
    scrollContainer.addEventListener("scroll", scrollListener);
    window.addEventListener("resize", scrollListener);
    return () => {
      scrollContainer.removeEventListener("scroll", scrollListener);
      window.removeEventListener("resize", scrollListener);
    };
  }, [ref]);
};
