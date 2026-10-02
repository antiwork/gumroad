import * as React from "react";

import { useDebouncedCallback } from "$app/components/useDebouncedCallback";

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
  // Set when a scroll to the track end clamps the counter to the last card; cleared as soon as the
  // counter changes any other way, so a card picked with the arrows is never mistaken for it.
  const endClampedIndexRef = React.useRef<number | null>(null);

  const handleScroll = useDebouncedCallback(() => {
    const items = itemsRef.current;
    if (!items) return;
    // The track cannot scroll far enough to put the last items at the left edge, so the offset
    // search below stops short of the final index when several cards fit in view.
    if (isScrolledToEnd(items)) {
      endClampedIndexRef.current = items.children.length - 1;
      setActiveIndex(items.children.length - 1);
      return;
    }
    setActiveIndex(leftEdgeIndex(items));
  }, 100);

  // At the end of the track the counter is the last card, but that card's offset is past the max
  // scroll, so stepping back from it would not move the track. Step from the card at the left
  // edge instead. Any other counter value is a card the buyer picked, so step from it.
  const getPreviousIndex = (count: number) => {
    const items = itemsRef.current;
    let from = activeIndex;
    if (items && endClampedIndexRef.current === activeIndex && isScrolledToEnd(items)) {
      const leftEdge = leftEdgeIndex(items);
      if (leftEdge > 0) from = leftEdge;
    }
    return (from + count - 1) % count;
  };

  React.useEffect(() => {
    if (endClampedIndexRef.current !== activeIndex) endClampedIndexRef.current = null;
    const activeChild = itemsRef.current?.children[activeIndex];
    itemsRef.current?.scroll({
      left: activeChild instanceof HTMLElement ? activeChild.offsetLeft : 0,
      behavior: "smooth",
    });
  }, [activeIndex]);

  return { itemsRef, handleScroll, getPreviousIndex };
}
