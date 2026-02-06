import * as React from "react";
import { cast } from "ts-safe-cast";

import { asyncVoid } from "$app/utils/promise";
import { assertResponseError, request } from "$app/utils/request";

import { Alert } from "$app/components/ui/Alert";

type Props = {
  show: boolean;
};

export const RefundPaymentMethodBanner = ({ show }: Props) => {
  const [isVisible, setIsVisible] = React.useState(show);
  const [isDismissing, setIsDismissing] = React.useState(false);

  const handleDismiss = asyncVoid(async () => {
    setIsDismissing(true);

    try {
      const response = await request({
        method: "POST",
        url: Routes.dismiss_banner_settings_refund_funding_path(),
        accept: "json",
      });

      const result = cast<{ success: boolean }>(await response.json());

      if (result.success) {
        setIsVisible(false);
      }
    } catch (e) {
      assertResponseError(e);
    }

    setIsDismissing(false);
  });

  if (!isVisible) return null;

  return (
    <Alert variant="accent" role="status">
      <div>
        <strong>New:</strong> Refund customers instantly, even when your balance is low. Add a backup payment method to
        cover refunds automatically if your balance can't.
        <div style={{ marginTop: "0.25rem" }}>
          <a href={`${Routes.settings_payments_path()}#refund-payment-method`}>Set up backup method</a>
        </div>
      </div>
      <button
        type="button"
        className="link"
        onClick={handleDismiss}
        disabled={isDismissing}
        aria-label="Dismiss"
      >
        close
      </button>
    </Alert>
  );
};

export default RefundPaymentMethodBanner;
