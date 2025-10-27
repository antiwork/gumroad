import React from "react";

import { LoadingSpinner } from "$app/components/LoadingSpinner";
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
          <LoadingSpinner />
        </li>
        <li>
          <LoadingSpinner />
        </li>
      </>
    );
  }

  const label = preorder_state ? "pre-orders" : "sales";
  const totalLabel = preorder_state ? "total (pre-order auths)" : "total";
  const formattedCount = count.toLocaleString();
  const formattedStripeFailedCount = stripe_failed_count.toLocaleString();
  const failedPercentage = stripe_failed_count / (stripe_failed_count + count);
  const formattedFailedPercentage = failedPercentage.toLocaleString(undefined, {
    style: "percent",
    maximumFractionDigits: 2,
  });
  return (
    <>
      <li>
        {formattedCount} {label}
        {stripe_failed_count > 0 && (
          <WithTooltip tip={formattedFailedPercentage}>&nbsp;({formattedStripeFailedCount} failed)</WithTooltip>
        )}
      </li>

      <li>
        {balance_formatted} {totalLabel}
      </li>
    </>
  );
};

export default AdminProductStatsSales;
