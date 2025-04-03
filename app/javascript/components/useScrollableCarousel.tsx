import * as React from "react";

import { useDebouncedCallback } from "$app/components/useDebouncedCallback";

export function useScrollableCarousel(activeIndex: number, setActiveIndex: (index: number) => void) {
  const itemsRef = React.useRef<HTMLDivElement>(null);

  const handleScroll = useDebouncedCallback(() => {
    const items = itemsRef.current;
    if (!items) return;
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
