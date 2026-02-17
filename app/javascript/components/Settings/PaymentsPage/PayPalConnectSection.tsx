import * as React from "react";
import { cast } from "ts-safe-cast";

import { asyncVoid } from "$app/utils/promise";
import { request } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { FormSection } from "$app/components/ui/FormSection";
import { InputGroup } from "$app/components/ui/InputGroup";
import { Label } from "$app/components/ui/Label";

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
    <FormSection
      header={
        <>
          <h2>PayPal</h2>
          <a href="/help/article/275-paypal-connect" target="_blank" rel="noreferrer">
            Learn more
          </a>
        </>
      }
    >
      <div className="flex flex-col gap-4">
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
                  <Button asChild color="paypal" disabled={isFormDisabled || !paypalConnect.allow_paypal_connect}>
                    <a
                      href={Routes.connect_paypal_path({
                        referer: Routes.settings_payments_path(),
                      })}
                      inert={isFormDisabled || !paypalConnect.allow_paypal_connect}
                    >
                      <span className="brand-icon brand-icon-paypal" />
                      Connect with Paypal
                    </a>
                  </Button>
                </div>
                {!paypalConnect.allow_paypal_connect ? (
                  <Alert variant="warning">
                    <p>You must meet the following requirements in order to connect a PayPal account:</p>
                    <ul>
                      <li>Your account must be marked as compliant</li>
                      <li>You must have earned at least $100</li>
                      <li>You must have received at least one successful payout</li>
                    </ul>
                  </Alert>
                ) : null}
              </>
            ) : null}
          </>
        ) : paypalConnect.charge_processor_verified ? (
          <>
            <p>{connectAccountFeeInfoText}</p>
            <div className="grid gap-8">
              <Fieldset>
                <FieldsetTitle>
                  <Label>PayPal account</Label>
                </FieldsetTitle>
                <InputGroup readOnly>
                  <span className="flex-1">{paypalConnect.charge_processor_merchant_id}</span>
                  <Icon name="solid-check-circle" className="text-success" />
                </InputGroup>
              </Fieldset>
              {paypalConnect.show_paypal_connect ? (
                <>
                  <p>
                    <Button
                      color="paypal"
                      aria-label="Disconnect PayPal account"
                      disabled={isFormDisabled || !paypalConnect.paypal_disconnect_allowed}
                      onClick={disconnectPayPal}
                    >
                      Disconnect PayPal account
                    </Button>
                  </p>
                  {!paypalConnect.paypal_disconnect_allowed ? (
                    <Alert variant="warning">
                      You cannot disconnect your PayPal account because it is being used for active subscription or
                      preorder payments.
                    </Alert>
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
                  <Button asChild color="paypal" disabled={isFormDisabled || !paypalConnect.allow_paypal_connect}>
                    <a
                      href={Routes.connect_paypal_path({
                        referer: Routes.settings_payments_path(),
                      })}
                      inert={isFormDisabled || !paypalConnect.allow_paypal_connect}
                    >
                      <span className="brand-icon brand-icon-paypal" />
                      Connect with Paypal
                    </a>
                  </Button>
                </p>
                {!paypalConnect.allow_paypal_connect ? (
                  <Alert variant="warning">
                    <p>You must meet the following requirements in order to connect a PayPal account:</p>
                    <ul>
                      <li>Your account must be marked as compliant</li>
                      <li>You must have earned at least $100</li>
                      <li>You must have received at least one successful payout</li>
                    </ul>
                  </Alert>
                ) : null}
                <Alert variant="warning">
                  Your PayPal account connect with Gumroad is incomplete because of missing permissions. Please try
                  connecting again and grant the requested permissions.
                </Alert>
              </>
            ) : null}
          </>
        )}
      </div>
    </FormSection>
  );
};
export default PayPalConnectSection;
