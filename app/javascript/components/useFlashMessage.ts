import { router } from "@inertiajs/react";
import * as React from "react";

import { showAlert, type AlertPayload } from "$app/components/server-components/Alert";

export function useFlashMessage(flash?: AlertPayload | null): void {
  React.useEffect(() => {
    if (!flash?.message) return;

    showAlert(flash.message, flash.status === "danger" ? "error" : flash.status);
    router.replaceProp("flash", null);
  }, [flash]);
}
