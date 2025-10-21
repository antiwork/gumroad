import React from "react";

const useRouteLoading = () => {
  const [isRouteLoading, setIsRouteLoading] = React.useState(false);

  React.useEffect(() => {
    const startHandler = (event: DocumentEventMap["inertia:start"]) => {
      const { prefetch, only = [], preserveScroll } = event.detail.visit;
      const shouldPreserveScroll = preserveScroll !== false;
      setIsRouteLoading(!prefetch && !shouldPreserveScroll && only.length === 0);
    };

    const finishHandler = (_event: DocumentEventMap["inertia:finish"]) => setIsRouteLoading(false);

    document.addEventListener("inertia:start", startHandler);
    document.addEventListener("inertia:finish", finishHandler);

    return () => {
      document.removeEventListener("inertia:start", startHandler);
      document.removeEventListener("inertia:finish", finishHandler);
    };
  }, []);

  return isRouteLoading;
};

export default useRouteLoading;
