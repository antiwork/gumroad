import cx from "classnames";
import * as React from "react";

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
      {showPayPalPayoutsFeeNote ? (
        <div className="info" role="status">
          PayPal payouts are subject to a 2% processing fee.
        </div>
      ) : null}
      <div className="whitespace-pre-line">{feeInfoText}</div>
      <div>
        {countrySupportsNativePayouts && !isFormDisabled ? (
          <button className="underline" onClick={() => updatePayoutMethod("bank")}>
            Switch to direct deposit
          </button>
        ) : null}
        <fieldset className={cx({ danger: errorFieldNames.has("paypal_email_address") })}>
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
        {hasConnectedStripe ? (
          <div role="alert" className="warning">
            You cannot change your payout method to PayPal because you have a stripe account connected.
          </div>
        ) : null}
      </div>
      {user.country_code === "UA" ? (
        <div role="alert" className="warning">
          <div>
            PayPal blocks commercial payments to Ukraine, which will prevent payouts to your PayPal account until
            further notice. Your balance will remain in your Gumroad account until this restriction is lifted or payouts
            are directed to a PayPal account outside of Ukraine.
          </div>
        </div>
      ) : null}
    </section>
  );
};
export default PayPalEmailSection;
