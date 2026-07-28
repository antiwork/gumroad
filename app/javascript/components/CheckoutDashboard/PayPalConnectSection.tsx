import { CheckCircle, Paypal } from "@boxicons/react";
import * as React from "react";
import typia from "typia";

import { asyncVoid } from "$app/utils/promise";
import { request } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
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
  paypal_disconnect_removes_payout_rail: boolean;
  paypal_disconnect_blocks_publishing: boolean;
  payout_setup_method: "bank_account" | "paypal_email";
};

const ConnectWithPayPalButton = ({ disabled }: { disabled: boolean }) => (
  <Button asChild color="paypal" disabled={disabled}>
    <a
      href={Routes.connect_paypal_path({ referer: Routes.checkout_form_path() })}
      inert={disabled}
      className={disabled ? "opacity-30" : undefined}
    >
      <Paypal pack="brands" className="size-5" />
      Connect with PayPal
    </a>
  </Button>
);

const EligibilityAlert = () => (
  <Alert variant="warning">
    You must set up how you receive payouts in your <a href={Routes.settings_payments_path()}>payout settings</a> before
    you can connect a PayPal account.
  </Alert>
);

const PayPalConnectSection = ({
  paypalConnect,
  connectAccountFeeInfoText,
}: {
  paypalConnect: PayPalConnect;
  connectAccountFeeInfoText: string;
}) => {
  const [confirmingDisconnect, setConfirmingDisconnect] = React.useState(false);

  const disconnectPayPal = asyncVoid(async () => {
    setConfirmingDisconnect(false);
    const response = await request({
      method: "POST",
      url: Routes.disconnect_paypal_path(),
      accept: "json",
    });

    const parsedResponse = typia.assert<{ success: boolean }>(await response.json());
    if (parsedResponse.success) {
      showAlert("Your PayPal account has been disconnected.", "success");
      window.location.reload();
    } else {
      showAlert("Sorry, something went wrong. Please try again.", "error");
    }
  });

  // Sellers who have never saved a bank account or a PayPal payout email are paid out to the
  // email on this connected account. Disconnecting takes that away and they cannot reconnect
  // afterwards, so ask them to confirm and tell them what to set up instead.
  const onDisconnectClick = () => {
    if (paypalConnect.paypal_disconnect_removes_payout_rail) setConfirmingDisconnect(true);
    else disconnectPayPal();
  };

  return (
    <section className="space-y-4 border-b border-border p-4 md:p-8">
      <header className="flex items-center justify-between">
        <h2>PayPal</h2>
        <a href="/help/article/275-paypal-connect" target="_blank" rel="noreferrer">
          Learn more
        </a>
      </header>
      <p>
        Optionally connect a personal or business PayPal account to let customers pay with PayPal at checkout. Each
        purchase made with PayPal is deposited into your PayPal account immediately. This is not how you receive payouts
        — payouts are configured in your <a href={Routes.settings_payments_path()}>payout settings</a>. Payments via
        PayPal are supported in every country except {paypalConnect.unsupported_countries.join(", ")}.
      </p>
      {!paypalConnect.charge_processor_merchant_id ? (
        <>
          <p>{connectAccountFeeInfoText}</p>
          <div>
            <ConnectWithPayPalButton disabled={!paypalConnect.allow_paypal_connect} />
          </div>
          {!paypalConnect.allow_paypal_connect ? <EligibilityAlert /> : null}
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
                <CheckCircle pack="filled" className="size-5 text-success" />
              </InputGroup>
            </Fieldset>
            <p>
              <Button
                color="paypal"
                aria-label="Disconnect PayPal account"
                disabled={!paypalConnect.paypal_disconnect_allowed}
                onClick={onDisconnectClick}
              >
                Disconnect PayPal account
              </Button>
            </p>
            <Modal
              open={confirmingDisconnect}
              onClose={() => setConfirmingDisconnect(false)}
              title="Disconnect PayPal account"
              footer={
                <>
                  <Button onClick={() => setConfirmingDisconnect(false)}>Cancel</Button>
                  <Button color="danger" onClick={disconnectPayPal}>
                    Disconnect
                  </Button>
                </>
              }
            >
              <p>
                You are currently paid out to the PayPal account connected here. Disconnecting it removes your only
                payout method, so your payouts will stop
                {paypalConnect.paypal_disconnect_blocks_publishing
                  ? " and you will not be able to publish products"
                  : ""}{" "}
                until you set up another one.
              </p>
              <p>
                {paypalConnect.payout_setup_method === "bank_account"
                  ? "In your country payouts go to a bank account, so add your bank account in your "
                  : "Add your PayPal payout email in your "}
                <a href={Routes.settings_payments_path()}>payout settings</a> to keep getting paid. You will not be able
                to reconnect PayPal here until you have done that.
              </p>
            </Modal>
            {!paypalConnect.paypal_disconnect_allowed ? (
              <Alert variant="warning">
                You cannot disconnect your PayPal account because it is being used for active subscription or preorder
                payments.
              </Alert>
            ) : null}
          </div>
        </>
      ) : (
        <>
          <p>{connectAccountFeeInfoText}</p>
          <p>
            <ConnectWithPayPalButton disabled={!paypalConnect.allow_paypal_connect} />
          </p>
          {!paypalConnect.allow_paypal_connect ? <EligibilityAlert /> : null}
          <Alert variant="warning">
            Your PayPal account connect with Gumroad is incomplete because of missing permissions. Please try connecting
            again and grant the requested permissions.
          </Alert>
        </>
      )}
    </section>
  );
};
export default PayPalConnectSection;
