import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { StandaloneLayout } from "$app/inertia/layout";

import { Button } from "$app/components/Button";
import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";

import { UnavailablePageLayout, type UnavailablePageProps } from "./UnavailablePageLayout";

import placeholderImage from "$assets/images/placeholders/comic-stars.png";

type Props = UnavailablePageProps;

const MembershipInactive = () => {
  const props = cast<Props>(usePage().props);

  const isInstallmentPlan = props.purchase?.membership?.is_installment_plan ?? false;
  const productName = props.purchase?.product_name ?? "";
  const productLongUrl = props.purchase?.product_long_url ?? null;
  const membership =
    props.purchase?.email && props.purchase.membership
      ? {
          is_alive_or_restartable: props.purchase.membership.is_alive_or_restartable,
          subscription_id: props.purchase.membership.subscription_id,
        }
      : null;
  const installmentPlan = {
    is_alive_or_restartable: props.purchase?.membership?.is_alive_or_restartable ?? null,
    subscription_id: props.purchase?.membership?.subscription_id ?? "",
  };

  return (
    <UnavailablePageLayout {...props} contentUnavailabilityReasonCode="inactive_membership">
      {isInstallmentPlan ? (
        <Placeholder className="flex-1 content-center">
          <PlaceholderImage src={placeholderImage} />
          <h2>Your installment plan is inactive</h2>
          {installmentPlan.is_alive_or_restartable ? (
            <>
              <p>Please update your payment method to continue accessing the content of {productName}.</p>
              <Button asChild color="primary">
                <a href={Routes.manage_subscription_url(installmentPlan.subscription_id)}>Update payment method</a>
              </Button>
            </>
          ) : (
            <p>You cannot access the content of {productName} because your installment plan is no longer active.</p>
          )}
        </Placeholder>
      ) : (
        <Placeholder className="flex-1 content-center">
          <PlaceholderImage src={placeholderImage} />
          <h2>Your membership is inactive</h2>
          <p>You cannot access the content of {productName} because your membership is no longer active.</p>
          {membership ? (
            membership.is_alive_or_restartable ? (
              <Button asChild color="primary">
                <a href={Routes.manage_subscription_url(membership.subscription_id)}>Manage membership</a>
              </Button>
            ) : productLongUrl ? (
              <Button asChild color="primary">
                <a href={productLongUrl}>Resubscribe</a>
              </Button>
            ) : null
          ) : null}
        </Placeholder>
      )}
    </UnavailablePageLayout>
  );
};

MembershipInactive.layout = (page: React.ReactNode) => <StandaloneLayout>{page}</StandaloneLayout>;

export default MembershipInactive;
