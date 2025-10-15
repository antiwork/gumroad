import * as React from "react";
import { cast } from "ts-safe-cast";

import { asyncVoid } from "$app/utils/promise";
import { request, assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { showAlert } from "$app/components/server-components/Alert";
import { SocialAuthButton } from "$app/components/SocialAuthButton";

export type StripeConnect = {
  has_connected_stripe: boolean;
  stripe_connect_account_id: string | null;
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
        <div className="paragraphs">
          <div
            dangerouslySetInnerHTML={{
              __html: `${connectAccountFeeInfoText}\n${stripeConnect.supported_countries_help_text}`,
            }}
            className="whitespace-pre-line"
          ></div>
        </div>
        {stripeConnect.has_connected_stripe ? (
          <div className="grid gap-8">
            <fieldset>
              <legend>
                <label>Stripe account</label>
              </legend>
              <div className="input input-wrapper">
                <div className="fake-input">{stripeConnect.stripe_connect_account_id}</div>
                <Icon name="solid-check-circle" style={{ color: "rgb(var(--success))" }} />
              </div>
            </fieldset>
            <p>
              <Button
                color="danger"
                className="button-stripe"
                disabled={isFormDisabled || isDisconnecting || !stripeConnect.stripe_disconnect_allowed}
                onClick={disconnectStripe}
              >
                Disconnect Stripe account
              </Button>
            </p>
            {!stripeConnect.stripe_disconnect_allowed ? (
              <div role="alert" className="warning">
                You cannot disconnect your Stripe account because it is being used for active subscription or preorder
                payments.
              </div>
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
              Connect with Stripe
            </SocialAuthButton>
          </div>
        )}
      </div>
    </section>
  );
};
export default StripeConnectSection;
