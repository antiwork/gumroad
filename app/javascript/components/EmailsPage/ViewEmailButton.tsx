import { Envelope } from "@boxicons/react";
import React from "react";

import { previewInstallment, SavedInstallment } from "$app/data/installments";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { showAlert } from "$app/components/server-components/Alert";

export const ViewEmailButton = (props: { installment: SavedInstallment }) => {
  const [sendingPreviewEmail, setSendingPreviewEmail] = React.useState(false);

  return (
    <Button
      disabled={sendingPreviewEmail}
      onClick={asyncVoid(async () => {
        setSendingPreviewEmail(true);
        try {
          await previewInstallment(props.installment.external_id);
          showAlert("A preview has been sent to your email.", "success");
        } catch (error) {
          assertResponseError(error);
          showAlert(error.message, "error");
        } finally {
          setSendingPreviewEmail(false);
        }
      })}
    >
      <Envelope pack="filled" className="size-5" />
      {sendingPreviewEmail ? "Sending..." : "View email"}
    </Button>
  );
};
