import { usePage } from "@inertiajs/react";
import React from "react";

import { default as BalancePage, BalancePageProps } from "$app/components/BalancePage";

function index() {
  const {
    next_payout_period_data,
    processing_payout_periods_data,
    payouts_status,
    payouts_paused_by,
    payouts_paused_for_reason,
    past_payout_period_data,
    instant_payout,
    show_instant_payouts_notice,
    pagination,
  } = usePage<BalancePageProps>().props;

  return (
    <BalancePage
      next_payout_period_data={next_payout_period_data}
      processing_payout_periods_data={processing_payout_periods_data}
      payouts_status={payouts_status}
      payouts_paused_by={payouts_paused_by}
      payouts_paused_for_reason={payouts_paused_for_reason}
      past_payout_period_data={past_payout_period_data}
      instant_payout={instant_payout}
      show_instant_payouts_notice={show_instant_payouts_notice}
      pagination={pagination}
    />
  );
}

export default index;
