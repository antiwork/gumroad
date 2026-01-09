import { usePage } from "@inertiajs/react";
import * as React from "react";

import { showAlert, type AlertPayload } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";

type PageProps = {
  flash?: AlertPayload;
};

export const AuthAlert: React.FC = () => {
  const { flash } = usePage<PageProps>().props;

  React.useEffect(() => {
    if (flash?.status === "success" && flash.message) {
      showAlert(flash.message, "success");
    }
  }, [flash]);

  if (flash?.status === "warning" && flash.message) {
    return <Alert variant="danger">{flash.message}</Alert>;
  }

  return null;
};
