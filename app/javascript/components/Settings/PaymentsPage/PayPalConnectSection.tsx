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
  restricted_countries_with_requirements: string[];
  earnings_requirement_met: boolean;
  payout_requirement_met: boolean;
  compliance_requirement_met: boolean;
  minimum_earnings_formatted: string;
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
            {paypalConnect.allow_paypal_connect ? (
              <div>
                <a
                  className="button button-paypal paypal-connect"
                  href={Routes.connect_paypal_path({
                    referer: Routes.settings_payments_path(),
                  })}
                  inert={isFormDisabled}
                >
                  Connect with Paypal
                </a>
              </div>
            ) : (
              <>
                {paypalConnect.restricted_countries_with_requirements.some(country => 
                  paypalConnect.unsupported_countries.includes(country)
                ) && (
                  <div role="alert" className="warning">
                    <p>To connect PayPal from your country, you must meet the following requirements:</p>
                    <ul>
                      {!paypalConnect.compliance_requirement_met && <li>Your account must be marked as compliant</li>}
                      {!paypalConnect.earnings_requirement_met && <li>You must have earned at least {paypalConnect.minimum_earnings_formatted}</li>}
                      {!paypalConnect.payout_requirement_met && <li>You must have received at least one successful payout</li>}
                    </ul>
                  </div>
                )}
              </>
            )}
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
              {paypalConnect.allow_paypal_connect ? (
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
            {paypalConnect.allow_paypal_connect ? (
              <>
                <p>
                  <a
                    className="button button-paypal paypal-connect"
                    href={Routes.connect_paypal_path({
                      referer: Routes.settings_payments_path(),
                    })}
                    inert={isFormDisabled}
                  >
                    Connect with Paypal
                  </a>
                </p>
                <div role="alert" className="warning">
                  Your PayPal account connect with Gumroad is incomplete because of missing permissions. Please try
                  connecting again and grant the requested permissions.
                </div>
              </>
            ) : (
              <>
                {paypalConnect.restricted_countries_with_requirements.some(country => 
                  paypalConnect.unsupported_countries.includes(country)
                ) && (
                  <div role="alert" className="warning">
                    <p>To connect PayPal from your country, you must meet the following requirements:</p>
                    <ul>
                      {!paypalConnect.compliance_requirement_met && <li>Your account must be marked as compliant</li>}
                      {!paypalConnect.earnings_requirement_met && <li>You must have earned at least {paypalConnect.minimum_earnings_formatted}</li>}
                      {!paypalConnect.payout_requirement_met && <li>You must have received at least one successful payout</li>}
                    </ul>
                  </div>
                )}
              </>
            )}
          </>
        )}
      </div>
    </section>
  );
};
export default PayPalConnectSection;
