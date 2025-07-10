import React from "react";

const useIsVisibleOnMount = (
  targetRef: React.RefObject<Element | null>,
  { threshold = 0, root = null, rootMargin = "0%" }: IntersectionObserverInit | undefined = {},
) => {
  const [entry, setEntry] = React.useState<IntersectionObserverEntry>();

  React.useEffect(() => {
    const element = targetRef.current;

    if (!element || entry) return;

    const ob = new IntersectionObserver(
      ([entry]: IntersectionObserverEntry[]) => {
        setEntry(entry);
      },
      { threshold, root, rootMargin },
    );

    ob.observe(element);

    return () => {
      ob.disconnect();
    };
  }, [entry, root, rootMargin, targetRef, threshold]);

  return entry?.isIntersecting ?? false;
};

export default useIsVisibleOnMount;
