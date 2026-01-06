import { router } from "@inertiajs/react";
import * as React from "react";

import { showAlert, type AlertPayload } from "$app/components/server-components/Alert";

/**
 * Hook to display flash messages and clear them from Inertia's cache.
 *
 * Flash messages were persisting across browser history navigations because
 * Inertia caches page props. This hook clears the flash prop after displaying
 * the message, preventing it from re-appearing when navigating back/forward.
 *
 * @see https://github.com/antiwork/gumroad/issues/2562
 */
export function useFlashMessage(flash?: AlertPayload | null): void {
  React.useEffect(() => {
    if (!flash?.message) return;

    showAlert(flash.message, flash.status === "danger" ? "error" : flash.status);

    // Clear flash from Inertia's page cache to prevent re-display on history navigation.
    // This is a client-side only operation and does not make a server request.
    router.replaceProp("flash", null);
  }, [flash]);
}
