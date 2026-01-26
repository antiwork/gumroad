import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Button } from "$app/components/Button";
import { LayoutProps } from "$app/components/server-components/DownloadPage/Layout";

import { UnavailablePage } from "./components/UnavailablePage";

type Props = LayoutProps & {
  purchase: LayoutProps["purchase"] & {
    product_name: string;
  } | null;
};

function MembershipInactive() {
  const props = cast<Props>(usePage().props);
  const { purchase } = props;
  const productName = purchase?.product_name ?? "this product";

  const isInstallmentPlan = purchase?.membership?.is_installment_plan;

  if (isInstallmentPlan) {
    return (
      <UnavailablePage {...props} product_name={productName} title_suffix="Your installment plan is inactive">
        <h2>Your installment plan is inactive</h2>
        {purchase?.membership?.is_alive_or_restartable ? (
          <>
            <p>Please update your payment method to continue accessing the content of {productName}.</p>
            <Button asChild color="primary">
              <a href={Routes.manage_subscription_url(purchase.membership.subscription_id)}>Update payment method</a>
            </Button>
          </>
        ) : (
          <p>You cannot access the content of {productName} because your installment plan is no longer active.</p>
        )}
      </UnavailablePage>
    );
  }

  return (
    <UnavailablePage {...props} product_name={productName} title_suffix="Your membership is inactive">
      <h2>Your membership is inactive</h2>
      <p>You cannot access the content of {productName} because your membership is no longer active.</p>
      {purchase?.email && purchase.membership ? (
        purchase.membership.is_alive_or_restartable ? (
          <Button asChild color="primary">
            <a href={Routes.manage_subscription_url(purchase.membership.subscription_id)}>Manage membership</a>
          </Button>
        ) : purchase.product_long_url ? (
          <Button asChild color="primary">
            <a href={purchase.product_long_url}>Resubscribe</a>
          </Button>
        ) : null
      ) : null}
    </UnavailablePage>
  );
}

MembershipInactive.loggedInUserLayout = true;
export default MembershipInactive;
