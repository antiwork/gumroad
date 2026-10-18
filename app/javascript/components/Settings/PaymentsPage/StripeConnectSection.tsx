import { CheckCircle, Stripe } from "@boxicons/react";
import * as React from "react";

import { cast } from "$app/utils/cast";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError, request } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { FeeInfoDetails, type FeeInfo } from "$app/components/FeeInfo";
import { showAlert } from "$app/components/server-components/Alert";
import { SocialAuthButton } from "$app/components/SocialAuthButton";
import { Alert } from "$app/components/ui/Alert";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { InputGroup } from "$app/components/ui/InputGroup";
import { Label } from "$app/components/ui/Label";

export type StripeConnect = {
  has_connected_stripe: boolean;
  stripe_connect_account_id: string | null;
  stripe_connect_routing_active: boolean;
  stripe_disconnect_allowed: boolean;
  supported_countries_help_text: string;
  payout_rail_setup?: PayoutRailSetup;
};

export type PayoutRailSetup = {
  submitted_payout_type: "bank account" | "debit card" | null;
  refused_payout_type: "bank account" | "debit card" | null;
  support_required: boolean;
};

// Shown instead of the "cannot change" warning when a new bank account or card is accepted for review
// beside a stored Connect link. The current payout method keeps being used until payouts are switched.
export const PayoutRailSetupNotice = ({
  payoutRailSetup,
  payoutType,
}: {
  payoutRailSetup: PayoutRailSetup;
  payoutType: "bank account" | "debit card";
}) => (
  <Alert variant="info">
    {payoutRailSetup.submitted_payout_type
      ? `We've received the ${payoutRailSetup.submitted_payout_type} you submitted. Your current payout method stays as it is until we switch your payouts to it.`
      : payoutRailSetup.support_required
        ? "We can't set up a new bank account or debit card for your account yet, so your current payout method stays as it is. Please contact support."
        : payoutRailSetup.refused_payout_type
          ? `We couldn't set up the ${payoutRailSetup.refused_payout_type} you submitted, so your current payout method stays as it is. You can submit a ${payoutType} here.`
          : `You can submit a ${payoutType} here. Your current payout method stays as it is until we switch your payouts to the new ${payoutType}.`}
  </Alert>
);

const StripeConnectSection = ({
  stripeConnect,
  isFormDisabled,
  connectAccountFeeInfo,
}: {
  stripeConnect: StripeConnect;
  isFormDisabled: boolean;
  connectAccountFeeInfo: FeeInfo;
}) => {
  const uid = React.useId();
  const [isDisconnecting, setisDisconnecting] = React.useState(false);
  const disconnectStripe = asyncVoid(async () => {
    setisDisconnecting(true);

    try {
      const response = await request({
        method: "POST",
        url: Routes.disconnect_settings_stripe_path(),
        accept: "json",
      });

      const parsedResponse = cast<{ success: boolean }>(await response.json());
      if (parsedResponse.success) {
        showAlert("Your Stripe account has been disconnected.", "success");
        window.location.reload();
      } else {
        showAlert("Sorry, something went wrong. Please try again.", "error");
      }
    } catch (e) {
      assertResponseError(e);
      showAlert("Sorry, something went wrong. Please try again.", "error");
    }

    setisDisconnecting(false);
  });

  return (
    <section className="grid gap-8">
      <FeeInfoDetails feeInfo={connectAccountFeeInfo} />
      {stripeConnect.has_connected_stripe ? (
        <>
          <div className="grid gap-4">
            <Fieldset>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-stripe-account`}>Stripe account</Label>
              </FieldsetTitle>
              <InputGroup disabled>
                <Input id={`${uid}-stripe-account`} disabled value={stripeConnect.stripe_connect_account_id ?? ""} />
                {stripeConnect.stripe_connect_routing_active ? (
                  <CheckCircle pack="filled" className="size-5 text-success" aria-label="Receiving card sales" />
                ) : null}
              </InputGroup>
            </Fieldset>
            {stripeConnect.stripe_connect_routing_active ? null : (
              <Alert role="status" variant="info">
                Card sales don't go to this Stripe account right now. They go to your Gumroad balance, and we pay them
                out on your regular payout schedule. Once a payout is scheduled, the{" "}
                <a href={Routes.balance_path()}>Payouts page</a> shows where it goes.
              </Alert>
            )}
          </div>
          <div className="grid gap-4">
            <div>
              <Button
                color="stripe"
                disabled={isFormDisabled || isDisconnecting || !stripeConnect.stripe_disconnect_allowed}
                onClick={disconnectStripe}
              >
                <Stripe pack="brands" className="size-5" />
                Disconnect Stripe account
              </Button>
            </div>
            {!stripeConnect.stripe_disconnect_allowed ? (
              <Alert variant="warning">
                You cannot disconnect your Stripe account because it is being used for active subscription or preorder
                payments.
              </Alert>
            ) : null}
          </div>
        </>
      ) : (
        <>
          <div dangerouslySetInnerHTML={{ __html: stripeConnect.supported_countries_help_text }} />
          <div>
            <SocialAuthButton
              provider="stripe"
              href={Routes.user_stripe_connect_omniauth_authorize_path({
                referer: Routes.settings_payments_path(),
              })}
              disabled={isFormDisabled}
            >
              <Stripe pack="brands" className="size-5" />
              Connect with Stripe
            </SocialAuthButton>
          </div>
        </>
      )}
    </section>
  );
};
export default StripeConnectSection;
