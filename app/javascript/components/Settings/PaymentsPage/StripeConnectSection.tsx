import { CheckCircle, Stripe } from "@boxicons/react";
import * as React from "react";

import { cast } from "$app/utils/cast";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError, request } from "$app/utils/request";

import { Button } from "$app/components/Button";
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
};

const StripeConnectSection = ({
  stripeConnect,
  isFormDisabled,
  connectAccountFeeInfoText,
}: {
  stripeConnect: StripeConnect;
  isFormDisabled: boolean;
  connectAccountFeeInfoText: string;
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
      <div className="whitespace-pre-line">{connectAccountFeeInfoText}</div>
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
                out on your regular payout schedule. The <a href={Routes.balance_path()}>Payouts page</a> shows where
                your next payout goes.
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
