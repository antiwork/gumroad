import * as React from "react";

import { Alert } from "$app/components/ui/Alert";
import { useFlashData } from "$app/components/useFlash";

export const WarningFlash: React.FC = () => {
  const flash = useFlashData();

  if (flash?.status === "warning") {
    return <Alert variant="danger">{flash.message}</Alert>;
  }

  return null;
};
