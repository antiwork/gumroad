import * as React from "react";

import {
  EU_WITHDRAWAL_CONSENT_FIELD_KEY,
  EU_WITHDRAWAL_CONSENT_TEXT,
  euWithdrawalConsentApplies,
} from "$app/components/Checkout/euWithdrawalConsent";
import { getErrors, isProcessing, useState } from "$app/components/Checkout/payment";
import { Checkbox } from "$app/components/ui/Checkbox";
import { Fieldset, FieldsetDescription } from "$app/components/ui/Fieldset";
import { Label } from "$app/components/ui/Label";

/**
 * The EU immediate-delivery / loss-of-withdrawal-right consent, for a buyer in an EU member state
 * whose cart holds something that is not a physical good. Required to pay (the submit-time
 * validation in `payment.ts` refuses a submit without it) and recorded on each purchase it covers,
 * then echoed on the receipt as the durable-medium confirmation.
 *
 * Renders nothing when it does not apply, so it is safe to mount unconditionally next to the
 * seller's custom fields.
 */
export const EuWithdrawalConsentField = ({ className }: { className?: string | undefined }) => {
  const [state, dispatch] = useState();
  const uid = React.useId();

  if (
    !euWithdrawalConsentApplies(
      state.country,
      state.products.map((product) => product.nativeType),
    )
  )
    return null;

  const hasError = getErrors(state).has(EU_WITHDRAWAL_CONSENT_FIELD_KEY);
  const checked = state.customFieldValues[EU_WITHDRAWAL_CONSENT_FIELD_KEY] === "true";

  return (
    <div className={className}>
      <Fieldset state={hasError ? "danger" : undefined}>
        <Label>
          <Checkbox
            checked={checked}
            aria-invalid={hasError}
            aria-describedby={hasError ? `${uid}-error` : undefined}
            onChange={(event) =>
              dispatch({
                type: "set-custom-field",
                key: EU_WITHDRAWAL_CONSENT_FIELD_KEY,
                value: event.target.checked ? "true" : "",
              })
            }
            style={{ margin: 0 }}
            disabled={isProcessing(state)}
          />
          {/* One flex item for the sentence and its link: as two siblings the anchor is its own
              flex item and shrinks to min-content, so "Learn more" wraps letter by letter. */}
          <span>
            {EU_WITHDRAWAL_CONSENT_TEXT}{" "}
            <a href="https://gumroad.com/help/article/190" target="_blank" rel="noreferrer">
              Learn more
            </a>
          </span>
        </Label>
        {hasError ? (
          <FieldsetDescription id={`${uid}-error`}>
            Please confirm that you want immediate access before you pay.
          </FieldsetDescription>
        ) : null}
      </Fieldset>
    </div>
  );
};
