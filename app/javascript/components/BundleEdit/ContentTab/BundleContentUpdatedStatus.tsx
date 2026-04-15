import { router } from "@inertiajs/react";
import * as React from "react";

import { Button } from "$app/components/Button";
import { Alert } from "$app/components/ui/Alert";

type BundleContentUpdatedStatusProps = {
  id: string;
};

export const BundleContentUpdatedStatus = ({ id }: BundleContentUpdatedStatusProps) => {
  const [isLoading, setIsLoading] = React.useState(false);

  const updatePurchases = () => {
    router.post(
      Routes.update_purchases_content_bundle_content_path(id),
      {},
      {
        preserveScroll: true,
        onStart: () => setIsLoading(true),
        onFinish: () => setIsLoading(false),
      },
    );
  };

  return (
    <Alert role="status" variant="info">
      <div className="flex flex-col gap-4">
        <strong>Some of your customers don't have access to the latest content in your bundle.</strong>
        Would you like to give them access and send them an email notification?
        <Button color="primary" onClick={updatePurchases} disabled={isLoading}>
          {isLoading ? "Updating..." : "Yes, update"}
        </Button>
      </div>
    </Alert>
  );
};
