import * as React from "react";

type ObserveElement = (element: Element, callback: (isIntersecting: boolean) => void) => () => void;

const NodeVisibilityContext = React.createContext<ObserveElement | null>(null);

export const NodeVisibilityProvider = ({
  scrollRef,
  children,
}: {
  scrollRef: React.RefObject<Element | null>;
  children: React.ReactNode;
}) => {
  const stableRef = React.useRef<{
    observer: IntersectionObserver;
    callbacks: Map<Element, (isIntersecting: boolean) => void>;
  } | null>(null);

  const getObserver = () => {
    if (!stableRef.current) {
      const callbacks = new Map<Element, (isIntersecting: boolean) => void>();
      const observer = new IntersectionObserver(
        (entries) => {
          for (const e of entries) {
            callbacks.get(e.target)?.(e.isIntersecting);
          }
        },
        { root: scrollRef.current, rootMargin: "1000px" },
      );
      stableRef.current = { observer, callbacks };
    }
    return stableRef.current;
  };

  const observe = React.useCallback<ObserveElement>((element, callback) => {
    const { observer, callbacks } = getObserver();
    callbacks.set(element, callback);
    observer.observe(element);

    return () => {
      callbacks.delete(element);
      observer.unobserve(element);
    };
  }, []);

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
