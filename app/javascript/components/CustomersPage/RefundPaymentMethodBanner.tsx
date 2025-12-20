import * as React from "react";
import { cast } from "ts-safe-cast";

import { asyncVoid } from "$app/utils/promise";
import { assertResponseError, request } from "$app/utils/request";

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
    <div
      className="info-box"
      role="status"
      style={{
        marginBottom: "1.5rem",
        display: "flex",
        alignItems: "center",
        gap: "1rem",
        padding: "1rem",
        backgroundColor: "rgb(255, 240, 243)",
        border: "1px solid rgb(255, 144, 185)",
        borderRadius: "4px",
      }}
    >
      <span style={{ fontSize: "2rem" }}>🖐️</span>
      <div style={{ flex: 1 }}>
        <strong>New:</strong> Refund customers instantly, even when your balance is low. Add a backup payment method to
        cover refunds automatically if your balance can't.{" "}
        <a href={`${Routes.settings_payments_path()}#refund-payment-method`} style={{ textDecoration: "underline" }}>
          Set up backup method
        </a>
      </div>
      <button
        type="button"
        className="link"
        onClick={handleDismiss}
        disabled={isDismissing}
        aria-label="Dismiss"
        style={{ color: "#666", cursor: "pointer" }}
      >
        close
      </button>
    </div>
  );
};

export default RefundPaymentMethodBanner;
