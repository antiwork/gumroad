import React from "react";

import Loading from "$app/components/Admin/Loading";
import Header from "$app/components/Admin/Users/PayoutInfo/Header";
import AdminManualPayoutForm from "$app/components/Admin/Users/PayoutInfo/ManualPayoutForm";
import AdminTogglePayoutsForm from "$app/components/Admin/Users/PayoutInfo/TogglePayoutsForm";

export type ActiveBankAccountProps = {
  type: string;
  account_holder_full_name: string;
  formatted_account: string;
};

export type PayoutInfoProps = {
  active_bank_account: ActiveBankAccountProps | null;
  payment_address: string | null;
  payouts_paused_by_source: "stripe" | "admin" | "system" | "user" | null;
  payouts_paused_for_reason: string | null;
  manual_payout_info: ManualPayoutInfoProps | null;
};

type StripePayoutInfoProps = {
  unpaid_balance_held_by_gumroad: string;
  unpaid_balance_held_by_stripe: string;
};

type PaypalPayoutInfoProps = {
  should_payout_be_split: boolean;
  split_payment_by_cents: number;
};

type ManualPayoutInfoProps = {
  stripe: StripePayoutInfoProps | null;
  paypal: PaypalPayoutInfoProps | null;
  unpaid_balance_up_to_date: number;
  currency: string | null;
  ask_confirmation: boolean;
  manual_payout_period_end_date: string;
};

type PayoutInfoComponentProps = {
  user_id: number;
  isLoading: boolean;
  payoutInfo: PayoutInfoProps | null;
};

const PayoutInfo = ({ user_id, payoutInfo, isLoading }: PayoutInfoComponentProps) => {
  if (isLoading) return <Loading />;
  if (!payoutInfo) return <div>No payout info found.</div>;

  const {
    active_bank_account,
    payment_address,
    payouts_paused_by_source,
    payouts_paused_for_reason,
    manual_payout_info,
  } = payoutInfo;

  return (
    <div className="paragraphs">
      <Header active_bank_account={active_bank_account} payment_address={payment_address} />
      <hr />
      <AdminTogglePayoutsForm
        user_id={user_id}
        payouts_paused_by={payouts_paused_by_source}
        reason={payouts_paused_for_reason}
      />
      {manual_payout_info ? <AdminManualPayoutForm user_id={user_id} {...manual_payout_info} /> : null}
    </div>
  );
};

export default PayoutInfo;
