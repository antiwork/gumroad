import * as React from "react";

import { NavigationButton } from "$app/components/Button";
import { Alert } from "$app/components/ui/Alert";

type MarketingEmailStatusProps = {
  bundleId: string;
  bundleName: string;
};

export const MarketingEmailStatus = ({ bundleId, bundleName }: MarketingEmailStatusProps) => {
  const [sendToAllCustomers, setSendToAllCustomers] = React.useState(false);
  
  // TODO: Get bundle data from page props or server
  // For now, we'll construct the URL with minimal params
  const queryParams = {
    template: "bundle_marketing",
    bundle_permalink: bundleId,
    bundle_name: bundleName,
  };

  return (
    <Alert role="status" variant="info">
      <div className="flex flex-col gap-4">
        <strong>
          Your product bundle is ready. Would you like to send an email about this offer to existing customers?
        </strong>
        <fieldset>
          <label>
            <input
              type="radio"
              checked={!sendToAllCustomers}
              onChange={(evt) => setSendToAllCustomers(!evt.target.checked)}
            />
            Customers who have purchased at least one product in the bundle
          </label>
          <label>
            <input
              type="radio"
              checked={sendToAllCustomers}
              onChange={(evt) => setSendToAllCustomers(evt.target.checked)}
            />
            All customers
          </label>
        </fieldset>
        <NavigationButton
          color="primary"
          href={Routes.new_email_path(queryParams)}
          target="_blank"
          rel="noopener noreferrer"
        >
          Draft and send
        </NavigationButton>
      </div>
    </Alert>
  );
};
