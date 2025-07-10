import React from "react";

const useIsVisibleOnMount = (targetRef: React.RefObject<Element | null>) => {
  const [isVisible, setIsVisible] = React.useState(false);

  React.useEffect(() => {
    const element = targetRef.current;
    if (!element) return;

    const rect = element.getBoundingClientRect();

    const isInViewport =
      rect.top >= 0 && rect.left >= 0 && rect.bottom <= window.innerHeight && rect.right <= window.innerWidth;

    setIsVisible(isInViewport);
  }, [targetRef]);

  return isVisible;
};
export default useIsVisibleOnMount;
