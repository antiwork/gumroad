import * as React from "react";

import { useDebouncedCallback } from "$app/components/useDebouncedCallback";

const SCROLL_END_TOLERANCE_PX = 2;

export function useScrollableCarousel(activeIndex: number, setActiveIndex: (index: number) => void) {
  const itemsRef = React.useRef<HTMLDivElement>(null);

  const handleScroll = useDebouncedCallback(() => {
    const items = itemsRef.current;
    if (!items) return;
    // The track cannot scroll far enough to put the last items at the left edge, so the offset
    // search below stops short of the final index when several cards fit in view.
    const isScrollable = items.scrollWidth > items.clientWidth;
    if (isScrollable && items.scrollLeft + items.clientWidth >= items.scrollWidth - SCROLL_END_TOLERANCE_PX) {
      setActiveIndex(items.children.length - 1);
      return;
    }
    setActiveIndex(
      [...items.children].findIndex(
        (child) => child instanceof HTMLElement && child.offsetLeft + child.offsetWidth / 5 >= items.scrollLeft,
      ),
    );
  }, 100);

  React.useEffect(() => {
    const activeChild = itemsRef.current?.children[activeIndex];
    itemsRef.current?.scroll({
      left: activeChild instanceof HTMLElement ? activeChild.offsetLeft : 0,
      behavior: "smooth",
    });
  }, [activeIndex]);

  return { itemsRef, handleScroll };
}
