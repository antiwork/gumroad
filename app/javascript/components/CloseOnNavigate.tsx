import { router } from "@inertiajs/react";
import * as React from "react";

import { useNav } from "$app/components/Nav";

export const CloseOnNavigate = () => {
  const nav = useNav();
  const close = nav?.close;

  React.useEffect(() => {
    if (!close) return;
    return router.on("before", (event) => {
      // Sidebar links prefetch on hover, and a prefetch request fires the same "before" event a
      // real page visit does. On a phone, tapping a link synthesises a mouseenter first, so the
      // prefetch would close the nav drawer while the finger is still down: the link disappears
      // before the tap turns into a click, and the first tap does nothing. Only close the drawer
      // when the user is actually navigating.
      if (event.detail.visit.prefetch) return;
      close();
    });
  }, [close]);

  return null;
};
