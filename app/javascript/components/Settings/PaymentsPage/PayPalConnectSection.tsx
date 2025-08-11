import * as React from "react";
import { cast } from "ts-safe-cast";

import { asyncVoid } from "$app/utils/promise";
import { request } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { showAlert } from "$app/components/server-components/Alert";

export type PayPalConnect = {
  email: string | null;
  charge_processor_merchant_id: string | null;
  charge_processor_verified: boolean;
  needs_email_confirmation: boolean;
  unsupported_countries: string[];
  show_paypal_connect: boolean;
  allow_paypal_connect: boolean;
  paypal_disconnect_allowed: boolean;
};

const PayPalConnectSection = ({
  paypalConnect,
  isFormDisabled,
  connectAccountFeeInfoText,
}: {
  paypalConnect: PayPalConnect;
  isFormDisabled: boolean;
  connectAccountFeeInfoText: string;
}) => {
  const disconnectPayPal = asyncVoid(async () => {
    const response = await request({
      method: "POST",
      url: Routes.disconnect_paypal_path(),
      accept: "json",
    });

    const parsedResponse = cast<{ success: boolean }>(await response.json());
    if (parsedResponse.success) {
      showAlert("Your PayPal account has been disconnected.", "success");
      window.location.reload();
    } else {
      showAlert("Sorry, something went wrong. Please try again.", "error");
    }
  });

  return (
    <section>
      <header>
        <h2>PayPal</h2>
        <a data-helper-prompt="How do I connect my PayPal account?">Learn more</a>
      </header>
      <div className="paragraphs">
        {!paypalConnect.charge_processor_merchant_id ? (
          <>
            <p>
              Connecting a personal or business PayPal account will allow you to accept payments with PayPal. Each
              purchase made with PayPal will be deposited into your PayPal account immediately. Payments via PayPal are
              supported in every country except {paypalConnect.unsupported_countries.join(", ")}.
            </p>
            <p>{connectAccountFeeInfoText}</p>
            {paypalConnect.show_paypal_connect ? (
              <>
                <div>
                  <a
                    className="button button-paypal paypal-connect"
                    href={Routes.connect_paypal_path({
                      referer: Routes.settings_payments_path(),
                    })}
                    inert={isFormDisabled || !paypalConnect.allow_paypal_connect}
                  >
                    Connect with Paypal
                  </a>
                </div>
                {!paypalConnect.allow_paypal_connect ? (
                  <div role="alert" className="warning">
                    <div>
                      <p>You must meet the following requirements in order to connect a PayPal account:</p>
                      <ul>
                        <li>Your account must be marked as compliant</li>
                        <li>You must have earned at least $100</li>
                        <li>You must have received at least one successful payout</li>
                      </ul>
                    </div>
                  </div>
                ) : null}
              </>
            ) : null}
          </>
        ) : paypalConnect.charge_processor_verified ? (
          <>
            <p>{connectAccountFeeInfoText}</p>
            <div style={{ display: "grid", gap: "var(--spacer-6)" }}>
              <fieldset>
                <legend>
                  <label>PayPal account</label>
                </legend>
                <div className="input input-wrapper">
                  <div className="fake-input">{paypalConnect.charge_processor_merchant_id}</div>
                  <Icon name="solid-check-circle" style={{ color: "rgb(var(--success))" }} />
                </div>
              </fieldset>
              {paypalConnect.show_paypal_connect ? (
                <>
                  <p>
                    <Button
                      color="danger"
                      className="button-paypal"
                      aria-label="Disconnect PayPal account"
                      disabled={isFormDisabled || !paypalConnect.paypal_disconnect_allowed}
                      onClick={disconnectPayPal}
                    >
                      Disconnect PayPal account
                    </Button>
                  </p>
                  {!paypalConnect.paypal_disconnect_allowed ? (
                    <div role="alert" className="warning">
                      You cannot disconnect your PayPal account because it is being used for active subscription or
                      preorder payments.
                    </div>
                  ) : null}
                </>
              ) : null}
            </div>
          </>
        ) : (
          <>
            <p>{connectAccountFeeInfoText}</p>
            {paypalConnect.show_paypal_connect ? (
              <>
                <p>
                  <a
                    className="button button-paypal paypal-connect"
                    href={Routes.connect_paypal_path({
                      referer: Routes.settings_payments_path(),
                    })}
                    inert={isFormDisabled || !paypalConnect.allow_paypal_connect}
                  >
                    Connect with Paypal
                  </a>
                </p>
                {!paypalConnect.allow_paypal_connect ? (
                  <div role="alert" className="warning">
                    <div>
                      <p>You must meet the following requirements in order to connect a PayPal account:</p>
                      <ul>
                        <li>Your account must be marked as compliant</li>
                        <li>You must have earned at least $100</li>
                        <li>You must have received at least one successful payout</li>
                      </ul>
                    </div>
                  </div>
                ) : null}
                <div role="alert" className="warning">
                  Your PayPal account connect with Gumroad is incomplete because of missing permissions. Please try
                  connecting again and grant the requested permissions.
                </div>
              </>
            ) : null}
          </>
        )}
      </div>
    </section>
  );
};
export default PayPalConnectSection;
