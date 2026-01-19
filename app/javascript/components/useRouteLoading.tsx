import React from "react";

const useRouteLoading = () => {
  const [isRouteLoading, setIsRouteLoading] = React.useState(false);
  const shouldScrollToTopRef = React.useRef(false);

  React.useEffect(() => {
    const startHandler = (event: DocumentEventMap["inertia:start"]) => {
      const { prefetch, only = [], preserveScroll } = event.detail.visit;
      const isFullPageNavigation = !prefetch && preserveScroll !== true && only.length === 0;
      shouldScrollToTopRef.current = isFullPageNavigation;
      setIsRouteLoading(isFullPageNavigation);
    };

    const finishHandler = (_event: DocumentEventMap["inertia:finish"]) => setIsRouteLoading(false);

    document.addEventListener("inertia:start", startHandler);
    document.addEventListener("inertia:finish", finishHandler);

    return () => {
      document.removeEventListener("inertia:start", startHandler);
      document.removeEventListener("inertia:finish", finishHandler);
    };
  }, []);

  React.useEffect(() => {
    if (!isRouteLoading && shouldScrollToTopRef.current) {
      document.querySelector("main")?.scrollTo(0, 0);
      shouldScrollToTopRef.current = false;
    }
  }, [isRouteLoading]);

  return isRouteLoading;
};

export default useRouteLoading;
