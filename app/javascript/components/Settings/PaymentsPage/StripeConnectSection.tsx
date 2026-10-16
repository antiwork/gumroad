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
  connectAccountFeeInfo,
}: {
  stripeConnect: StripeConnect;
  isFormDisabled: boolean;
  connectAccountFeeInfo: FeeInfo;
}) => {
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
    <section>
      <div className="grid gap-8">
        <div className="flex flex-col gap-4">
          <FeeInfoDetails feeInfo={connectAccountFeeInfo} />
          <p dangerouslySetInnerHTML={{ __html: stripeConnect.supported_countries_help_text }} />
        </div>
        {stripeConnect.has_connected_stripe ? (
          <div className="grid gap-8">
            <Fieldset>
              <FieldsetTitle>
                <Label>Stripe account</Label>
              </FieldsetTitle>
              <InputGroup readOnly>
                <span className="flex-1">{stripeConnect.stripe_connect_account_id}</span>
                {stripeConnect.stripe_connect_routing_active ? (
                  <CheckCircle pack="filled" className="size-5 text-success" />
                ) : null}
              </InputGroup>
              {stripeConnect.stripe_connect_routing_active ? null : (
                <p>This Stripe account is linked, but it is not currently receiving card sales.</p>
              )}
            </Fieldset>
            <p>
              <Button
                color="stripe"
                disabled={isFormDisabled || isDisconnecting || !stripeConnect.stripe_disconnect_allowed}
                onClick={disconnectStripe}
              >
                <Stripe pack="brands" className="size-5" />
                Disconnect Stripe account
              </Button>
            </p>
            {!stripeConnect.stripe_disconnect_allowed ? (
              <Alert variant="warning">
                You cannot disconnect your Stripe account because it is being used for active subscription or preorder
                payments.
              </Alert>
            ) : null}
          </div>
        ) : (
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
        )}
      </div>
    </section>
  );
};
export default StripeConnectSection;
