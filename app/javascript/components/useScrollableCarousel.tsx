import * as React from "react";

import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useRefToLatest } from "$app/components/useRefToLatest";

const SCROLL_END_TOLERANCE_PX = 2;

const leftEdgeIndex = (items: HTMLElement) =>
  [...items.children].findIndex(
    (child) => child instanceof HTMLElement && child.offsetLeft + child.offsetWidth / 5 >= items.scrollLeft,
  );

// Overflow within the tolerance is not scrollable, so the track is never "at its end" at scrollLeft 0.
const isScrolledToEnd = (items: HTMLElement) => {
  const overflow = items.scrollWidth - items.clientWidth;
  return overflow > SCROLL_END_TOLERANCE_PX && items.scrollLeft >= overflow - SCROLL_END_TOLERANCE_PX;
};

export function useScrollableCarousel(activeIndex: number, setActiveIndex: (index: number) => void) {
  const itemsRef = React.useRef<HTMLDivElement>(null);
  const activeIndexRef = useRefToLatest(activeIndex);
  // True while the counter shows the last card because the scroll handler put it there, not
  // because an arrow stepped to it.
  const endClampedRef = React.useRef(false);

  const handleScroll = useDebouncedCallback(() => {
    const items = itemsRef.current;
    if (!items) return;
    // The track cannot scroll far enough to put the last items at the left edge, so the offset
    // search below stops short of the final index when several cards fit in view.
    if (isScrolledToEnd(items)) {
      const last = items.children.length - 1;
      if (activeIndexRef.current !== last) endClampedRef.current = true;
      setActiveIndex(last);
      return;
    }
    endClampedRef.current = false;
    setActiveIndex(leftEdgeIndex(items));
  }, 100);

  // When the scroll handler clamped the counter to the last card, that card's offset is past the
  // max scroll, so stepping back from it would not move the track. Step from the card at the left
  // edge instead. A counter that an arrow set steps back one card, so Previous undoes Next.
  const getPreviousIndex = (count: number) => {
    const items = itemsRef.current;
    let from = activeIndex;
    if (items && endClampedRef.current && activeIndex === count - 1 && isScrolledToEnd(items)) {
      const leftEdge = leftEdgeIndex(items);
      if (leftEdge > 0) from = leftEdge;
    }
    return (from + count - 1) % count;
  };

  React.useEffect(() => {
    if (activeIndex !== (itemsRef.current?.children.length ?? 0) - 1) endClampedRef.current = false;
    const activeChild = itemsRef.current?.children[activeIndex];
    itemsRef.current?.scroll({
      left: activeChild instanceof HTMLElement ? activeChild.offsetLeft : 0,
      behavior: "smooth",
    });
  }, [activeIndex]);

  return { itemsRef, handleScroll, getPreviousIndex };
}
