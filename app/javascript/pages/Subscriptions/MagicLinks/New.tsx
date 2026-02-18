import { Link, useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Layout } from "$app/components/Authentication/Layout";
import { Button } from "$app/components/Button";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { useOriginalLocation } from "$app/components/useOriginalLocation";

type UserEmail = { email: string; source: string };

type Props = {
  product_name: string;
  subscription_id: string;
  is_installment_plan: boolean;
  user_emails: [UserEmail, ...UserEmail[]];
  email_sent: string | null;
};

function SubscriptionsMagicLink() {
  const { product_name, subscription_id, is_installment_plan, user_emails, email_sent } = cast<Props>(usePage().props);

  const hasSentEmail = email_sent !== null;
  const defaultEmailSource = email_sent ?? user_emails[0].source;
  const form = useForm({ email_source: defaultEmailSource });
  const selectedEmail = user_emails.find((e) => e.source === form.data.email_source) ?? user_emails[0];

  const subscriptionEntity = is_installment_plan ? "installment plan" : "membership";
  const invalid = new URL(useOriginalLocation()).searchParams.get("invalid") === "true";

  const sendMagicLink = (e: React.FormEvent) => {
    e.preventDefault();
    form.post(Routes.subscription_magic_link_path(subscription_id));
  };

  const title = hasSentEmail
    ? `We've sent a link to ${selectedEmail.email}.`
    : invalid
      ? "Your magic link has expired."
      : "You're currently not signed in.";
  const subtitle = hasSentEmail
    ? `Please check your inbox and click the link in your email to manage your ${subscriptionEntity}.`
    : user_emails.length > 1
      ? `To manage your ${subscriptionEntity} for ${product_name}, choose one of the emails associated with your account to receive a magic link.`
      : `To manage your ${subscriptionEntity} for ${product_name}, click the button below to receive a magic link at ${selectedEmail.email}`;

  return (
    <Layout
      header={
        <>
          <h1 className="mt-12">{title}</h1>
          <h3>{subtitle}</h3>
        </>
      }
      headerActions={<a href={Routes.login_path()}>Log in</a>}
    >
      <form onSubmit={sendMagicLink}>
        <section>
          {hasSentEmail ? (
            <>
              <Button color="primary" type="submit" disabled={form.processing}>
                {form.processing ? <LoadingSpinner /> : null}
                Resend magic link
              </Button>
              <p>
                {user_emails.length > 1 ? (
                  <>
                    Can't see the email? Please check your spam folder.{" "}
                    <Link href={Routes.new_subscription_magic_link_path(subscription_id)} className="underline">
                      Click here to choose another email
                    </Link>{" "}
                    or try resending the link above.
                  </>
                ) : (
                  "Can't see the email? Please check your spam folder or try resending the link above."
                )}
              </p>
            </>
          ) : (
            <>
              {user_emails.length > 1 ? (
                <fieldset>
                  <legend>Choose an email</legend>
                  {user_emails.map((userEmail) => (
                    <label key={userEmail.source}>
                      <input
                        type="radio"
                        name="email_source"
                        value={userEmail.source}
                        onChange={() => form.setData("email_source", userEmail.source)}
                        checked={userEmail.source === selectedEmail.source}
                      />
                      {userEmail.email}
                    </label>
                  ))}
                </fieldset>
              ) : null}
              <Button color="primary" type="submit" disabled={form.processing}>
                {form.processing ? <LoadingSpinner /> : null}
                Send magic link
              </Button>
            </>
          )}
        </section>
      </form>
    </Layout>
  );
}

SubscriptionsMagicLink.publicLayout = true;

export default SubscriptionsMagicLink;
