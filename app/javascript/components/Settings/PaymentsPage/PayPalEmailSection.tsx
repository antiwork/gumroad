import * as React from "react";

import type { FormFieldName, PayoutMethod } from "$app/types/payments";

import { Alert } from "$app/components/ui/Alert";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";

const PayPalEmailSection = ({
  canSetupBankPayouts,
  showPayPalPayoutsFeeNote,
  isFormDisabled,
  paypalEmailAddress,
  setPaypalEmailAddress,
  hasConnectedStripe,
  feeInfoText,
  updatePayoutMethod,
  errorFieldNames,
  user,
  countryName,
}: {
  canSetupBankPayouts: boolean;
  showPayPalPayoutsFeeNote: boolean;
  isFormDisabled: boolean;
  paypalEmailAddress: string | null;
  setPaypalEmailAddress: (newPaypalEmailAddress: string) => void;
  hasConnectedStripe: boolean;
  feeInfoText: string;
  updatePayoutMethod: (payoutMethod: PayoutMethod) => void;
  errorFieldNames: Set<FormFieldName>;
  user: { country_code: string | null; no_payout_rail_in_country: boolean };
  countryName: string | null;
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
      <div className="grid gap-4">
        {canSetupBankPayouts && !isFormDisabled ? (
          <button
            type="button"
            className="cursor-pointer justify-self-start underline all-unset"
            onClick={() => updatePayoutMethod("bank")}
          >
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
      {user.no_payout_rail_in_country ? (
        <Alert variant="warning">
          PayPal does not let accounts registered in {countryName ?? "your country"} receive money, so a payout to one
          will fail, and bank payouts are not available there either. To get paid you need a PayPal account registered
          in a country PayPal can pay into. Your balance stays in your Gumroad account in the meantime.
        </Alert>
      ) : null}
    </section>
  );
};

export default PayPalEmailSection;
