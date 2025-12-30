import { usePage } from "@inertiajs/react";
import * as React from "react";

import { type AlertPayload } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";

type PageProps = {
  flash?: AlertPayload;
};

export const WarningFlash: React.FC = () => {
  const { flash } = usePage<PageProps>().props;

  if (flash?.status === "warning" && flash.message) {
    return <Alert variant="danger">{flash.message}</Alert>;
  }

  return null;
};
