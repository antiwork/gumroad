import * as React from "react";

import type { FormFieldName, PayoutMethod } from "$app/types/payments";

import { Alert } from "$app/components/ui/Alert";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";

const PayPalEmailSection = ({
  countrySupportsNativePayouts,
  showPayPalPayoutsFeeNote,
  isFormDisabled,
  paypalEmailAddress,
  setPaypalEmailAddress,
  hasConnectedStripe,
  feeInfoText,
  updatePayoutMethod,
  errorFieldNames,
  user,
}: {
  countrySupportsNativePayouts: boolean;
  showPayPalPayoutsFeeNote: boolean;
  isFormDisabled: boolean;
  paypalEmailAddress: string | null;
  setPaypalEmailAddress: (newPaypalEmailAddress: string) => void;
  hasConnectedStripe: boolean;
  feeInfoText: string;
  updatePayoutMethod: (payoutMethod: PayoutMethod) => void;
  errorFieldNames: Set<FormFieldName>;
  user: { country_code: string | null };
}) => {
  const uid = React.useId();
  return (
    <section className="grid gap-8">
      {showPayPalPayoutsFeeNote ? (
        <Alert role="status" variant="info">
          PayPal payouts are subject to a 2% processing fee.
        </Alert>
      ) : null}
      <div className="whitespace-pre-line">{feeInfoText}</div>
      <div>
        {countrySupportsNativePayouts && !isFormDisabled ? (
          <button className="cursor-pointer underline all-unset" onClick={() => updatePayoutMethod("bank")}>
            Switch to direct deposit
          </button>
        ) : null}
        <Fieldset state={errorFieldNames.has("paypal_email_address") ? "danger" : undefined}>
          <FieldsetTitle>
            <Label htmlFor={`${uid}-paypal-email`}>PayPal Email</Label>
          </FieldsetTitle>
          <Input
            type="email"
            id={`${uid}-paypal-email`}
            placeholder="PayPal Email"
            value={paypalEmailAddress || ""}
            disabled={isFormDisabled}
            aria-invalid={errorFieldNames.has("paypal_email_address")}
            onChange={(evt) => setPaypalEmailAddress(evt.target.value)}
          />
        </Fieldset>
        {hasConnectedStripe ? (
          <Alert variant="warning">
            You cannot change your payout method to PayPal because you have a stripe account connected.
          </Alert>
        ) : null}
      </div>
      {user.country_code === "UA" ? (
        <Alert variant="warning">
          PayPal blocks commercial payments to Ukraine, which will prevent payouts to your PayPal account until further
          notice. Your balance will remain in your Gumroad account until this restriction is lifted or payouts are
          directed to a PayPal account outside of Ukraine.
        </Alert>
      ) : null}
    </section>
  );
};

export default PayPalEmailSection;
