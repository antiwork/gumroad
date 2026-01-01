import { router } from "@inertiajs/react";
import React from "react";

import { showAlert, type AlertPayload } from "$app/components/server-components/Alert";

export function useFlashMessage(flash?: AlertPayload) {
  React.useEffect(() => {
    if (flash?.message) {
      showAlert(flash.message, flash.status === "danger" ? "error" : flash.status);

      // Clear the flash from the current page's cached props to prevent it from
      // reappearing when navigating back via browser history
      router.reload({ only: ['flash'] });
    }
  }, [flash]);
}
