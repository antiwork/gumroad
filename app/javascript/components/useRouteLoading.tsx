import { Inertia } from "@inertiajs/inertia";
import React from "react";

function useRouteLoading() {
  const [isRouteLoading, setIsRouteLoading] = React.useState(false);

  React.useEffect(() => {
    const startHandler = () => setIsRouteLoading(true);
    const finishHandler = () => setIsRouteLoading(false);

    Inertia.on("start", startHandler);
    Inertia.on("finish", finishHandler);
  }, []);

  return isRouteLoading;
}

export default useRouteLoading;
