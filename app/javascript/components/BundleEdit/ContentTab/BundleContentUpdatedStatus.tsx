import * as React from "react";

import { updatePurchasesContent } from "$app/data/bundle";
import { assertResponseError } from "$app/utils/request";

import { useBundleEditContext } from "$app/components/BundleEdit/state";
import { Button } from "$app/components/Button";
import { showAlert } from "$app/components/server-components/Alert";

export const BundleContentUpdatedStatus = () => {
  const { id } = useBundleEditContext();
  const [isHidden, setIsHidden] = React.useState(false);
  const [isLoading, setIsLoading] = React.useState(false);

  const handleSubmit = async () => {
    setIsLoading(true);
    try {
      await updatePurchasesContent(id);
      showAlert("Queued an update to the content of all outdated purchases.", "success");
      setIsHidden(true);
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setIsLoading(false);
  };

  if (isHidden) return null;

  return (
    <div role="status" className="info">
      <div className="flex flex-col gap-4">
        <strong>Some of your customers don't have access to the latest content in your bundle.</strong>
        Would you like to give them access and send them an email notification?
        <Button color="primary" onClick={() => void handleSubmit()} disabled={isLoading}>
          Yes, update
        </Button>
      </div>
    </div>
  );
};
