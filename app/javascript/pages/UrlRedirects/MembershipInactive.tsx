import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { StandaloneLayout } from "$app/inertia/layout";

import { Button } from "$app/components/Button";
import { Layout, LayoutProps } from "$app/components/server-components/DownloadPage/Layout";
import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";

import placeholderImage from "$assets/images/placeholders/comic-stars.png";

type PageProps = LayoutProps;

const fullHeightPlaceholderClassName = "flex-1 content-center";

function MembershipInactivePage() {
  const pageProps = cast<PageProps>(usePage().props);
  const { purchase } = pageProps;

  const isInstallmentPlan = purchase?.membership?.is_installment_plan;

  return (
    <Layout {...pageProps}>
      {isInstallmentPlan ? (
        <InstallmentPlanFailedOrCancelled
          product_name={purchase.product_name ?? ""}
          installment_plan={{
            is_alive_or_restartable: purchase.membership?.is_alive_or_restartable ?? null,
            subscription_id: purchase.membership?.subscription_id ?? "",
          }}
        />
      ) : (
        <MembershipInactiveContent
          product_name={purchase?.product_name ?? ""}
          product_long_url={purchase?.product_long_url ?? null}
          membership={
            purchase?.email && purchase.membership
              ? {
                  is_alive_or_restartable: purchase.membership.is_alive_or_restartable,
                  subscription_id: purchase.membership.subscription_id,
                }
              : null
          }
        />
      )}
    </Layout>
  );
}

const MembershipInactiveContent = ({
  product_name,
  product_long_url,
  membership,
}: {
  product_name: string;
  product_long_url: string | null;
  membership: {
    is_alive_or_restartable: boolean | null;
    subscription_id: string;
  } | null;
}) => (
  <Placeholder className={fullHeightPlaceholderClassName}>
    <PlaceholderImage src={placeholderImage} />
    <h2>Your membership is inactive</h2>
    <p>You cannot access the content of {product_name} because your membership is no longer active.</p>
    {membership ? (
      membership.is_alive_or_restartable ? (
        <Button asChild color="primary">
          <a href={Routes.manage_subscription_url(membership.subscription_id)}>Manage membership</a>
        </Button>
      ) : product_long_url ? (
        <Button asChild color="primary">
          <a href={product_long_url}>Resubscribe</a>
        </Button>
      ) : null
    ) : null}
  </Placeholder>
);

const InstallmentPlanFailedOrCancelled = ({
  product_name,
  installment_plan,
}: {
  product_name: string;
  installment_plan: {
    subscription_id: string;
    is_alive_or_restartable: boolean | null;
  };
}) => (
  <Placeholder className={fullHeightPlaceholderClassName}>
    <PlaceholderImage src={placeholderImage} />
    <h2>Your installment plan is inactive</h2>
    {installment_plan.is_alive_or_restartable ? (
      <>
        <p>Please update your payment method to continue accessing the content of {product_name}.</p>
        <Button asChild color="primary">
          <a href={Routes.manage_subscription_url(installment_plan.subscription_id)}>Update payment method</a>
        </Button>
      </>
    ) : (
      <p>You cannot access the content of {product_name} because your installment plan is no longer active.</p>
    )}
  </Placeholder>
);

MembershipInactivePage.layout = (page: React.ReactNode) => <StandaloneLayout>{page}</StandaloneLayout>;

export default MembershipInactivePage;
