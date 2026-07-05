import * as React from "react";

import { useRefToLatest } from "$app/components/useRefToLatest";

// True when the element is a scroll container (can scroll vertically).
// Check overflowY rather than the `overflow` shorthand: a style like
// `overflow: hidden auto` computes to overflowY "auto" but the shorthand
// reads "hidden auto", which a naive `overflow === "auto"` check misses.
const isScrollContainer = (element: HTMLElement) => {
  const { overflowY } = getComputedStyle(element);
  return overflowY === "auto" || overflowY === "scroll";
};

export const useOnScrollToBottom = (
  ref: React.MutableRefObject<HTMLElement | null>,
  cb: () => void,
  threshold?: number,
) => {
  const cbRef = useRefToLatest(cb);
  React.useEffect(() => {
    if (!ref.current) return;
    let el: HTMLElement | null = ref.current;
    while (el && !isScrollContainer(el)) el = el.parentElement;
    // When no scrollable ancestor exists, the page itself is the scroller.
    // Scroll events for normal page scrolling fire on window/document, NOT on
    // document.body, so we must listen on window and measure the viewport via
    // document.scrollingElement (listening on document.body never fires and
    // its scrollTop stays 0, which silently breaks infinite scroll).
    const scrollContainer = el;
    const eventTarget: EventTarget = scrollContainer ?? window;
    const scrollListener = () => {
      if (scrollContainer) {
        if (scrollContainer.scrollTop + scrollContainer.offsetHeight > scrollContainer.scrollHeight - (threshold ?? 0))
          cbRef.current();
      } else {
        const scroller = document.scrollingElement ?? document.documentElement;
        if (scroller.scrollTop + scroller.clientHeight > scroller.scrollHeight - (threshold ?? 0)) cbRef.current();
      }
    };
    scrollListener();
    eventTarget.addEventListener("scroll", scrollListener);
    window.addEventListener("resize", scrollListener);
    return () => {
      eventTarget.removeEventListener("scroll", scrollListener);
      window.removeEventListener("resize", scrollListener);
    };
  }, [ref]);
};
