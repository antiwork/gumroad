import React from "react";

import Loading from "$app/components/Admin/Loading";
import { WithTooltip } from "$app/components/WithTooltip";

export type AdminProductStatsSalesProps = {
  preorder_state: boolean;
  count: number;
  stripe_failed_count: number;
  balance_formatted: string;
};

type Props = {
  salesStats: AdminProductStatsSalesProps;
  isLoading: boolean;
};

const AdminProductStatsSales = ({
  salesStats: { preorder_state, count, stripe_failed_count, balance_formatted },
  isLoading,
}: Props) => {
  if (isLoading) {
    return (
      <>
        <li>
          <Loading />
        </li>
        <li>
          <Loading />
        </li>
      </>
    );
  }

  const label = preorder_state ? "pre-orders" : "sales";
  const totalLabel = preorder_state ? "total (pre-order auths)" : "total";
  const formattedCount = new Intl.NumberFormat().format(count);
  const formattedStripeFailedCount = new Intl.NumberFormat().format(stripe_failed_count);
  const failedPercentage = stripe_failed_count / (stripe_failed_count + count);
  const formattedFailedPercentage = new Intl.NumberFormat().format(failedPercentage);
  return (
    <>
      <li>
        {formattedCount} {label}
        {stripe_failed_count > 0 && (
          <WithTooltip tip={formattedFailedPercentage}>{formattedStripeFailedCount} failed</WithTooltip>
        )}
      </li>

      <li>
        {balance_formatted} {totalLabel}
      </li>
    </>
  );
};

export default AdminProductStatsSales;
