import * as React from "react";

export const useIsIntersecting = (element: React.RefObject<HTMLElement>) => {
  const [isIntersecting, setIsIntersecting] = React.useState(false);

  React.useEffect(() => {
    if (!element.current) return;
    const observer = new IntersectionObserver((entries) =>
      setIsIntersecting(entries.some((entry) => entry.isIntersecting)),
    );
    observer.observe(element.current);
    return () => observer.disconnect();
  }, [element]);

  return isIntersecting;
};
