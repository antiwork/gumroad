import { router, usePage } from "@inertiajs/react";
import * as React from "react";

import { useDropbox } from "$app/hooks/useDropbox";
import { cast } from "$app/utils/cast";
import { pageWasRestoredFromHistory } from "$app/utils/popstateClaims";

import { ProductEditBoundary } from "$app/components/ProductEdit/Boundary";
import { LazyProductEditPage } from "$app/components/ProductEdit/load";
import { ProductEditLoadingSkeleton } from "$app/components/ProductEdit/LoadingSkeleton";
// Type-only: importing the editor's props must not pull its (large) module into this chunk.
import type { ProductEditPageProps } from "$app/components/server-components/ProductEditPage";

type PageProps = ProductEditPageProps & {
  dropbox_api_key: string | null;
};

export default function ProductEditInertiaPage() {
  const props = cast<PageProps>(usePage().props);
  const { dropbox_api_key, ...editProps } = props;

  useDropbox(dropbox_api_key);

  // Back or Forward to the editor mounts it with the props its history entry was first loaded
  // with, which predate every save made since. The editor saves from those props, so it waits for
  // the current ones.
  const [awaitingCurrentProps, setAwaitingCurrentProps] = React.useState(pageWasRestoredFromHistory);
  const [reloadAttempt, setReloadAttempt] = React.useState(0);
  React.useEffect(() => {
    if (!awaitingCurrentProps) return;
    let reloaded = false;
    let stopWaiting: (() => void) | undefined;
    let unmounted = false;
    router.reload({
      onSuccess: () => {
        reloaded = true;
        setAwaitingCurrentProps(false);
      },
      onFinish: (visit) => {
        if (reloaded || unmounted) return;
        // Another visit replaced this reload: ask again once it is done, if this page is still up.
        if (visit.cancelled || visit.interrupted) {
          stopWaiting = router.on("finish", () => {
            stopWaiting?.();
            setReloadAttempt((attempt) => attempt + 1);
          });
        } else window.location.reload();
      },
    });
    return () => {
      unmounted = true;
      stopWaiting?.();
    };
  }, [awaitingCurrentProps, reloadAttempt]);
  if (awaitingCurrentProps) return <ProductEditLoadingSkeleton title={editProps.product.name} />;

  // The editor's own code is loaded on demand (see ProductEdit/load), so this page can appear the
  // moment the server responds and show a skeleton of the editor while the rest arrives. The
  // Products list starts fetching that code while the seller is still reading it, so most of the
  // time the editor is ready immediately and the skeleton never appears. If that code cannot be
  // downloaded at all, the boundary shows a way out instead of letting the failed load blank the
  // page.
  return (
    <ProductEditBoundary>
      <React.Suspense fallback={<ProductEditLoadingSkeleton title={editProps.product.name} />}>
        {/* Keyed by product: Inertia keeps this page component mounted across
            client-side visits, and the editor seeds its state from props once
            (useState(props.product)) — without the key, product A's editor
            state survives into product B's URL. */}
        <LazyProductEditPage key={editProps.id} {...editProps} />
      </React.Suspense>
    </ProductEditBoundary>
  );
}
