import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { InlineAlert } from "$app/components/InlineAlert";
import { FormFieldName, PayoutMethod } from "$app/components/server-components/Settings/PaymentsPage";

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
      {showPayPalPayoutsFeeNote && (
        <InlineAlert variant="info" role="status">
          PayPal payouts are subject to a 2% processing fee.
        </InlineAlert>
      )}
      <div className="whitespace-pre-line">{feeInfoText}</div>
      <div>
        {countrySupportsNativePayouts && !isFormDisabled ? (
          <button className="underline" onClick={() => updatePayoutMethod("bank")}>
            Switch to direct deposit
          </button>
        ) : null}
        <fieldset className={classNames(errorFieldNames.has("paypal_email_address") && "danger")}>
          <legend>
            <label htmlFor={`${uid}-paypal-email`}>PayPal Email</label>
          </legend>
          <input
            type="email"
            id={`${uid}-paypal-email`}
            placeholder="PayPal Email"
            value={paypalEmailAddress || ""}
            disabled={isFormDisabled}
            aria-invalid={errorFieldNames.has("paypal_email_address")}
            onChange={(evt) => setPaypalEmailAddress(evt.target.value)}
          />
        </fieldset>
        {hasConnectedStripe && (
          <InlineAlert variant="warning">
            You cannot change your payout method to PayPal because you have a stripe account connected.
          </InlineAlert>
        )}
      </div>
      {user.country_code === "UA" && (
        <InlineAlert variant="warning">
          PayPal blocks commercial payments to Ukraine, which will prevent payouts to your PayPal account until further
          notice. Your balance will remain in your Gumroad account until this restriction is lifted or payouts are
          directed to a PayPal account outside of Ukraine.
        </InlineAlert>
      )}
    </section>
  );
};
export default PayPalEmailSection;
