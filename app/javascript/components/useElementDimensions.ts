import * as React from "react";

export const useElementDimensions = (ref: React.RefObject<HTMLElement>) => {
  const [dimensions, setDimensions] = React.useState<DOMRect | null>(null);
  React.useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const updateDimensions = () => {
      const { x, y } = el.getBoundingClientRect();
      setDimensions(new DOMRect(x, y, el.clientWidth, el.clientHeight));
    };
    const observer = new ResizeObserver(updateDimensions);
    observer.observe(el);
    updateDimensions();
    return () => observer.disconnect();
  }, [ref.current]);
  return dimensions;
};
