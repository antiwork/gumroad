import * as React from "react";

type ObserveElement = (element: Element, callback: (isIntersecting: boolean) => void) => () => void;

const NodeVisibilityContext = React.createContext<ObserveElement | null>(null);

// An element only works as a root while it is the thing that scrolls: otherwise target and root move
// together and no further intersections are ever generated. Reading the computed overflow keeps this
// in step with the layout's own breakpoints instead of restating them.
const scrollRootFor = (element: Element | null): Element | null => {
  if (!element) return null;
  const { overflowY } = getComputedStyle(element);
  return overflowY === "auto" || overflowY === "scroll" ? element : null;
};

export const NodeVisibilityProvider = ({
  scrollRef,
  children,
}: {
  scrollRef: React.RefObject<Element | null>;
  children: React.ReactNode;
}) => {
  const callbacks = React.useRef(new Map<Element, (isIntersecting: boolean) => void>()).current;
  const observerRef = React.useRef<IntersectionObserver | null>(null);
  // undefined until the first resolve, so we don't build an observer against a root we haven't read yet.
  const [root, setRoot] = React.useState<Element | null | undefined>(undefined);

  React.useEffect(() => {
    const resolve = () => setRoot(scrollRootFor(scrollRef.current));
    resolve();
    window.addEventListener("resize", resolve);
    return () => window.removeEventListener("resize", resolve);
  }, [scrollRef]);

  React.useEffect(() => {
    // Without the API, skip observing entirely: nodes stay in the hook's visible-by-default fallback.
    if (root === undefined || typeof IntersectionObserver === "undefined") return;

    const observer = new IntersectionObserver(
      (entries) => {
        for (const e of entries) callbacks.get(e.target)?.(e.isIntersecting);
      },
      { root, rootMargin: "1000px" },
    );
    observerRef.current = observer;
    // Nodes mount before this effect, and survive a root change, so re-observe everything registered.
    for (const element of callbacks.keys()) observer.observe(element);

    return () => {
      observer.disconnect();
      observerRef.current = null;
    };
  }, [root, callbacks]);

  const observe = React.useCallback<ObserveElement>(
    (element, callback) => {
      callbacks.set(element, callback);
      observerRef.current?.observe(element);

      return () => {
        callbacks.delete(element);
        observerRef.current?.unobserve(element);
      };
    },
    [callbacks],
  );

  return <NodeVisibilityContext.Provider value={observe}>{children}</NodeVisibilityContext.Provider>;
};

// Mimics virtualized scrolling for file nodes in the editor, where we can't use react-virtualized etc.
// This dramatically improves performance when there are thousands of files being rendered.
export const useNodeVisibility = (initialHeight: number) => {
  const ref = React.useRef<HTMLDivElement>(null);
  const [visible, setVisible] = React.useState(typeof IntersectionObserver === "undefined");
  const lastHeight = React.useRef(initialHeight);
  const observe = React.useContext(NodeVisibilityContext);

  React.useEffect(() => {
    const element = ref.current;
    if (!element || !observe) return;

    return observe(element, (isIntersecting) => {
      if (!isIntersecting) lastHeight.current = element.offsetHeight;
      setVisible(isIntersecting);
    });
  }, [observe]);

  return { ref, visible, lastHeight };
};
