import { router } from "@inertiajs/react";
import * as React from "react";

import { useNav } from "$app/components/Nav";

export const CloseOnNavigate = () => {
  const nav = useNav();
  const close = nav?.close;

  React.useEffect(() => {
    if (!close) return;
    return router.on("before", (event) => {
      // Inertia fires "before" for background requests as well as real page visits, and closing
      // the drawer for one of those yanks the links out from under the user's finger: below the
      // `lg` breakpoint the link list only exists while the drawer is open, so the tap target
      // disappears before the tap becomes a click and the tap does nothing.
      //
      // `prefetch` covers the sidebar's hover prefetching — on a phone a tap synthesises a
      // mouseenter first, which is what made the first tap on a sidebar link get swallowed.
      // `async` covers polling and lazily-loaded props (router.reload, WhenVisible), which can
      // fire at any moment while the drawer is open. A navigation the user actually asked for is
      // never either of these.
      const { visit } = event.detail;
      if (visit.prefetch || visit.async) return;
      close();
    });
  }, [close]);

  return null;
};
