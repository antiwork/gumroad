import { Link } from "@inertiajs/react";
import { subDays } from "date-fns";
import React from "react";

import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";
import { formatDate } from "$app/utils/date";

import { AdminActionButton } from "$app/components/Admin/ActionButton";
import DateTimeWithRelativeTooltip from "$app/components/Admin/DateTimeWithRelativeTooltip";

export type Payout = {
  external_id: string;
  displayed_amount: string;
  user: { external_id: string; name: string };
  processor: string;
  payout_period_end_date: string;
  processor_fee_cents: number;
  state: string;
  is_stripe_processor: boolean;
  is_paypal_processor: boolean;
  stripe_transfer_id: string | null;
  stripe_transfer_url: string | null;
  stripe_connect_account_id: string | null;
  stripe_connected_account_url: string | null;
  failed: boolean;
  humanized_failure_reason: string | null;
  bank_account: {
    credit_card: { visual: string };
    formatted_account: string;
  } | null;
  payment_address: string | null;
  txn_id: string | null;
  correlation_id: string | null;
  was_created_in_split_mode: boolean;
  split_payments_info: Record<string, unknown>[] | null;
  cancelled: boolean;
  returned: boolean;
  processing: boolean;
  created_at: string;
  unclaimed: boolean;
  non_terminal_state: boolean;
};

type Props = {
  payout: Payout;
};

const Payout = ({ payout }: Props) => (
  <div className="grid gap-4 rounded border border-border bg-background p-4">
    <div>
      <h3>
        <span>{payout.displayed_amount} to&nbsp;</span>
        <Link href={Routes.admin_user_path(payout.user.external_id)} title={payout.user.external_id}>
          {payout.user.name}
        </Link>
      </h3>

      <DateTimeWithRelativeTooltip date={payout.created_at} />
    </div>

    <hr />

    <dl>
      <dt>External ID</dt>
      <dd>
        <Link href={Routes.admin_payout_path(payout.external_id)} title={payout.external_id}>
          {payout.external_id}
        </Link>
      </dd>

      <dt>Processor</dt>
      <dd>{payout.processor.toUpperCase()}</dd>

      <dt>Payout period end date</dt>
      <dd>
        {payout.payout_period_end_date
          ? formatDate(new Date(payout.payout_period_end_date), { dateStyle: "long" })
          : "None"}
      </dd>

      <dt>Fee</dt>
      <dd>
        {formatPriceCentsWithCurrencySymbol("usd", payout.processor_fee_cents, {
          symbolFormat: "long",
          noCentsIfWhole: true,
        })}
      </dd>

      <dt>State</dt>
      <dd>{payout.state}</dd>

      {payout.is_stripe_processor ? (
        <>
          <dt>Stripe Transfer ID</dt>
          <dd>
            <a
              href={payout.stripe_transfer_url ?? ""}
              target="_blank"
              rel="noopener noreferrer"
              title={`View Stripe transfer ${payout.stripe_transfer_id}`}
            >
              {payout.stripe_transfer_id ?? "N/A"}
            </a>
          </dd>

          <dt>Stripe Account ID</dt>
          <dd>
            <a
              href={payout.stripe_connected_account_url ?? ""}
              target="_blank"
              rel="noopener noreferrer"
              title={`View Stripe connected account ${payout.stripe_connect_account_id}`}
            >
              {payout.stripe_connect_account_id ?? "N/A"}
            </a>
          </dd>
        </>
      ) : null}

      {payout.failed ? (
        <>
          <dt>Failure reason</dt>
          <dd>{payout.humanized_failure_reason ?? "None provided"}</dd>
        </>
      ) : null}

      {payout.bank_account ? (
        <>
          <dt>Account holder's name</dt>
          <dd>{payout.bank_account.credit_card.visual}</dd>

          <dt>Account</dt>
          <dd>{payout.bank_account.formatted_account}</dd>
        </>
      ) : (
        <>
          <dt>PayPal email</dt>
          <dd>{payout.payment_address ?? "None provided"}</dd>

          <dt>PayPal Transaction ID</dt>
          <dd>{payout.txn_id ?? "None provided"}</dd>

          <dt>PayPal Correlation ID</dt>
          <dd>{payout.correlation_id ?? "None provided"}</dd>

          {payout.was_created_in_split_mode ? (
            <>
              <dt>Split payment info</dt>
              <dd>
                <pre>{JSON.stringify(payout.split_payments_info ?? [], null, 2)}</pre>
              </dd>
            </>
          ) : null}
        </>
      )}
    </dl>

    <hr />

    <div className="flex gap-2">
      {payout.cancelled || payout.failed || payout.returned ? (
        <AdminActionButton
          url={Routes.retry_admin_payout_path(payout.external_id)}
          label="Retry"
          confirm_message="Are you sure you want to retry this payment?"
          loading="Retrying..."
          done="Retried."
        />
      ) : payout.processing && new Date(payout.created_at) <= subDays(new Date(), 2) ? (
        <AdminActionButton
          url={Routes.fail_admin_payout_path(payout.external_id)}
          label="Mark failed"
          confirm_message="Are you sure you want to mark this payment as failed?"
          loading="Marking failed..."
          done="Marked failed."
        />
      ) : payout.unclaimed ? (
        <AdminActionButton
          url={Routes.cancel_admin_payout_path(payout.external_id)}
          label="Mark cancelled"
          confirm_message="Are you sure you want to mark this payment as cancelled?"
          loading="Cancelling..."
          done="Cancelled!"
        />
      ) : null}

      {payout.is_paypal_processor && payout.non_terminal_state ? (
        <AdminActionButton
          url={Routes.sync_admin_payout_path(payout.external_id)}
          label="Sync with PayPal"
          confirm_message="Are you sure you want to try and sync this payment with PayPal?"
          loading="Syncing..."
          done="Synced!"
        />
      ) : null}
    </div>
  </div>
);

export default Payout;
