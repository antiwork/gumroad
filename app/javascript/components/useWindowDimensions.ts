import { throttle } from "lodash-es";
import * as React from "react";

// Lets the consumer observe changes to the window dimensions/size.
//
// Notice that the first returning value will always be `null` for both properties, since
// during SSR there is no `window`.
export const useWindowDimensions = (throttleDelay?: number) => {
  const [dimensions, setDimensions] = React.useState<{ width: number; height: number } | null>(null);

  React.useEffect(() => {
    const resizeHandler = () => setDimensions({ width: window.innerWidth, height: window.innerHeight });
    const throttledResizeHandler = throttleDelay ? throttle(resizeHandler, throttleDelay) : resizeHandler;
    throttledResizeHandler(); // first trigger
    window.addEventListener("resize", throttledResizeHandler);
    return () => window.removeEventListener("resize", throttledResizeHandler);
  }, [throttleDelay]);

  return dimensions;
};
