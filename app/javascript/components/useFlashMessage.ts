import { router } from "@inertiajs/react";
import React from "react";

import { showAlert, type AlertPayload } from "$app/components/server-components/Alert";

export function useFlashMessage(flash?: AlertPayload) {
  React.useEffect(() => {
    if (flash?.message) {
      showAlert(flash.message, flash.status === "danger" ? "error" : flash.status);

      // Clear the flash from Inertia's cache by updating props client-side
      // This does NOT make a server request - it only updates the local cache
      router.replace({
        props: (currentProps) => ({
          ...currentProps,
          flash: null,
        }),
      });
    }
  }, [flash]);
}
