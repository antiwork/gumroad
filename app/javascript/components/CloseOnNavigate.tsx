import { router } from "@inertiajs/react";
import * as React from "react";

import { useNav } from "$app/components/Nav";

export const CloseOnNavigate = () => {
  const nav = useNav();
  const close = nav?.close;

  React.useEffect(() => {
    if (!close) return;
    return router.on("before", close);
  }, [close]);

  return null;
};
