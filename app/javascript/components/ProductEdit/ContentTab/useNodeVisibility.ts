import * as React from "react";

const findScrollParent = (element: Element): Element | null => {
  let current = element.parentElement;
  while (current) {
    const { overflowY } = getComputedStyle(current);
    if (overflowY === "auto" || overflowY === "scroll") return current;
    current = current.parentElement;
  }
  return null;
};

const observersByScrollParent = new Map<
  Element | null,
  { observer: IntersectionObserver; callbacks: Map<Element, (isIntersecting: boolean) => void> }
>();

const addObserverForScrollParent = (element: Element, callback: (isIntersecting: boolean) => void) => {
  const root = findScrollParent(element);
  let entry = observersByScrollParent.get(root);
  if (!entry) {
    const callbacks = new Map<Element, (isIntersecting: boolean) => void>();
    const observer = new IntersectionObserver(
      (entries) => {
        for (const e of entries) {
          callbacks.get(e.target)?.(e.isIntersecting);
        }
      },
      { root, rootMargin: "1000px" },
    );
    entry = { observer, callbacks };
    observersByScrollParent.set(root, entry);
  }

  entry.callbacks.set(element, callback);
  entry.observer.observe(element);

  return () => {
    entry.callbacks.delete(element);
    entry.observer.unobserve(element);
  };
};

export const useNodeVisibility = (initialHeight: number) => {
  const ref = React.useRef<HTMLDivElement>(null);
  const [visible, setVisible] = React.useState(typeof IntersectionObserver === "undefined");
  const lastHeight = React.useRef(initialHeight);

  React.useEffect(() => {
    const element = ref.current;
    if (!element) return;

    return addObserverForScrollParent(element, (isIntersecting) => {
      if (!isIntersecting) lastHeight.current = element.offsetHeight;
      setVisible(isIntersecting);
    });
  }, []);

  return { ref, visible, lastHeight };
};
