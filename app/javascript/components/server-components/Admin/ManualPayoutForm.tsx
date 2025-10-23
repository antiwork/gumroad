import * as React from "react";
import { createCast } from "ts-safe-cast";

import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";
import { register } from "$app/utils/serverComponentUtil";

import { Form } from "$app/components/server-components/Admin/Form";
import { showAlert } from "$app/components/server-components/Alert";

export const AdminManualPayoutForm = ({
  user_id,
  stripe,
  paypal,
  manual_payout_period_end_date,
  unpaid_balance_up_to_date,
  currency,
  ask_confirmation,
}: {
  user_id: number;
  stripe: {
    unpaid_balance_held_by_gumroad: string;
    unpaid_balance_held_by_stripe: string;
  } | null;
  paypal: {
    should_payout_be_split: boolean;
    split_payment_by_cents: number;
  } | null;
  manual_payout_period_end_date: string;
  unpaid_balance_up_to_date: number;
  currency: string | null;
  ask_confirmation: boolean;
}) => (
  <Form
    url={Routes.admin_pay_user_path(user_id)}
    method="POST"
    confirmMessage={ask_confirmation ? "DON'T USE UNLESS to transfer the balance to Stripe Connect account" : false}
    onSuccess={() => showAlert("Successfully issued payout.", "success")}
  >
    {(isLoading) => (
      <fieldset>
        <input type="hidden" name="payday[payout_processor]" value={stripe ? "STRIPE" : "PAYPAL"} />
        <input type="hidden" name="payday[payout_period_end_date]" value={manual_payout_period_end_date} />
        {stripe ? (
          <div>
            <p>
              (held by Gumroad: {stripe.unpaid_balance_held_by_gumroad}, held in their Gumroad-managed Stripe account:{" "}
              {stripe.unpaid_balance_held_by_stripe} {currency})
            </p>
          </div>
        ) : null}
        {paypal ? (
          <div>
            {unpaid_balance_up_to_date > paypal.split_payment_by_cents && (
              <label>
                <input
                  type="checkbox"
                  name="payday[should_split_the_amount]"
                  defaultChecked={paypal.should_payout_be_split}
                  className="small"
                />
                Break up into {paypal.split_payment_by_cents} chunks?
              </label>
            )}
          </div>
        ) : null}
        <div className="button-group">
          <button type="submit" disabled={isLoading} className="button small">
            {isLoading ? "Issuing Payout..." : "Issue Payout"}
          </button>
        </div>
        <small>
          Balance that will be paid by clicking this button:{" "}
          {formatPriceCentsWithCurrencySymbol("usd", unpaid_balance_up_to_date, { symbolFormat: "short" })}
        </small>
      </fieldset>
    )}
  </Form>
);

export default register({ component: AdminManualPayoutForm, propParser: createCast() });
