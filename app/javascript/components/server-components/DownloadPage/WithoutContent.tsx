import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import Placeholder from "$app/components/ui/Placeholder";

import { Layout, LayoutProps } from "./Layout";

import placeholderImage from "$assets/images/placeholders/comic-stars.png";

const WithoutContent = ({ confirmation_info, authenticity_token, ...props }: LayoutProps & EmailConfirmationProps) => (
  <Layout {...props}>
    {props.content_unavailability_reason_code === "inactive_membership" ? (
      props.purchase?.membership?.is_installment_plan ? (
        <InstallmentPlanFailedOrCancelled
          product_name={props.purchase.product_name ?? ""}
          installment_plan={{
            is_alive_or_restartable: props.purchase.membership.is_alive_or_restartable,
            subscription_id: props.purchase.membership.subscription_id,
          }}
        />
      ) : (
        <MembershipInactive
          product_name={props.purchase?.product_name ?? ""}
          product_long_url={props.purchase?.product_long_url ?? null}
          membership={
            props.purchase?.email && props.purchase.membership
              ? {
                  is_alive_or_restartable: props.purchase.membership.is_alive_or_restartable,
                  subscription_id: props.purchase.membership.subscription_id,
                }
              : null
          }
        />
      )
    ) : props.content_unavailability_reason_code === "rental_expired" ? (
      <RentalExpired />
    ) : props.content_unavailability_reason_code === "access_expired" ? (
      <AccessExpired />
    ) : props.content_unavailability_reason_code === "email_confirmation_required" ? (
      <EmailConfirmation confirmation_info={confirmation_info} authenticity_token={authenticity_token} />
    ) : null}
  </Layout>
);

const MembershipInactive = ({
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
  <Placeholder>
    <figure>
      <img src={placeholderImage} />
    </figure>
    <h2>Your membership is inactive</h2>
    <p>You cannot access the content of {product_name} because your membership is no longer active.</p>
    {membership ? (
      membership.is_alive_or_restartable ? (
        <a className="button primary" href={Routes.manage_subscription_url(membership.subscription_id)}>
          Manage membership
        </a>
      ) : product_long_url ? (
        <a className="button primary" href={product_long_url}>
          Resubscribe
        </a>
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
  <Placeholder>
    <figure>
      <img src={placeholderImage} />
    </figure>
    <h2>Your installment plan is inactive</h2>
    {installment_plan.is_alive_or_restartable ? (
      <>
        <p>Please update your payment method to continue accessing the content of {product_name}.</p>
        <a className="button primary" href={Routes.manage_subscription_url(installment_plan.subscription_id)}>
          Update payment method
        </a>
      </>
    ) : (
      <p>You cannot access the content of {product_name} because your installment plan is no longer active.</p>
    )}
  </Placeholder>
);

const AccessExpired = () => (
  <Placeholder>
    <figure>
      <img src={placeholderImage} />
    </figure>
    <h2>Access expired</h2>
    <p>It looks like your access to this product has expired. Please contact the creator for further assistance.</p>
  </Placeholder>
);

const RentalExpired = () => (
  <Placeholder>
    <figure>
      <img src={placeholderImage} />
    </figure>
    <h2>Your rental has expired</h2>
    <p>Rentals expire 30 days after purchase or 72 hours after you’ve begun watching it.</p>
  </Placeholder>
);

type EmailConfirmationProps = {
  authenticity_token?: string | undefined;
  confirmation_info?:
    | {
        id: string;
        destination: string | null;
        display: string | null;
        email: string | null;
      }
    | undefined;
};
const EmailConfirmation = ({ confirmation_info, authenticity_token }: EmailConfirmationProps) => (
  <Placeholder>
    <h2>You've viewed this product a few times already</h2>
    <p>Once you enter the email address used to purchase this product, you'll be able to access it again.</p>
    {confirmation_info ? (
      <form
        action={Routes.confirm_redirect_path()}
        className="paragraphs"
        style={{ width: "calc(min(428px, 100%))" }}
        method="post"
      >
        <input type="hidden" name="utf8" value="✓" />
        {authenticity_token ? <input type="hidden" name="authenticity_token" value={authenticity_token} /> : null}
        <input type="hidden" name="id" value={confirmation_info.id} />
        <input type="hidden" name="destination" value={confirmation_info.destination ?? ""} />
        <input type="hidden" name="display" value={confirmation_info.display ?? ""} />
        <input type="text" name="email" placeholder="Email address" defaultValue={confirmation_info.email ?? ""} />
        <Button type="submit" color="accent">
          Confirm email
        </Button>
      </form>
    ) : null}
  </Placeholder>
);

export default register({ component: WithoutContent, propParser: createCast() });
