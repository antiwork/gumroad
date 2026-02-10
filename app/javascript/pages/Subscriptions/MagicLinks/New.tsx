import { Link, router, usePage } from "@inertiajs/react";
import * as React from "react";

import { Layout } from "$app/components/Authentication/Layout";
import { Button } from "$app/components/Button";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { showAlert } from "$app/components/server-components/Alert";
import { useOriginalLocation } from "$app/components/useOriginalLocation";

type UserEmail = { email: string; source: string };

type PageProps = {
  subscription_id: string;
  is_installment_plan: boolean;
  user_emails: UserEmail[];
  product_name: string;
};

function SubscriptionMagicLinkPage() {
  const { subscription_id, is_installment_plan, user_emails, product_name } = usePage<PageProps>().props;

  const [loading, setLoading] = React.useState(false);
  const [hasSentEmail, setHasSentEmail] = React.useState(false);
  const [selectedUserEmail, setSelectedUserEmail] = React.useState(user_emails[0]);

  const subscriptionEntity = is_installment_plan ? "installment plan" : "membership";
  const invalid = new URL(useOriginalLocation()).searchParams.get("invalid") === "true";

  const handleSendMagicLink = () => {
    setLoading(true);
    router.post(
      Routes.send_magic_link_subscription_path(subscription_id),
      { email_source: selectedUserEmail?.source },
      {
        preserveState: true,
        preserveScroll: true,
        onSuccess: () => {
          if (hasSentEmail) {
            showAlert(`Magic link resent to ${selectedUserEmail?.email}.`, "success");
          }
          setHasSentEmail(true);
          setLoading(false);
        },
        onError: () => {
          showAlert("Error sending magic link email", "error");
          setLoading(false);
        },
      },
    );
  };

  const title = hasSentEmail
    ? `We've sent a link to ${selectedUserEmail?.email}.`
    : invalid
      ? "Your magic link has expired."
      : "You're currently not signed in.";

  const subtitle = hasSentEmail
    ? `Please check your inbox and click the link in your email to manage your ${subscriptionEntity}.`
    : user_emails.length > 1
      ? `To manage your ${subscriptionEntity} for ${product_name}, choose one of the emails associated with your account to receive a magic link.`
      : `To manage your ${subscriptionEntity} for ${product_name}, click the button below to receive a magic link at ${selectedUserEmail?.email}`;

  return (
    <Layout
      header={
        <>
          <h1 className="mt-12">{title}</h1>
          <h3>{subtitle}</h3>
        </>
      }
      headerActions={<Link href={Routes.login_path()}>Log in</Link>}
    >
      <form>
        <section>
          {hasSentEmail ? (
            <>
              <Button color="primary" onClick={handleSendMagicLink} disabled={loading}>
                {loading ? <LoadingSpinner /> : null}
                Resend magic link
              </Button>
              <p>
                {user_emails.length > 1 ? (
                  <>
                    Can't see the email? Please check your spam folder.{" "}
                    <button
                      type="button"
                      className="cursor-pointer underline all-unset"
                      onClick={() => setHasSentEmail(false)}
                    >
                      Click here to choose another email
                    </button>{" "}
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
                        onChange={() => setSelectedUserEmail(userEmail)}
                        checked={userEmail === selectedUserEmail}
                      />
                      {userEmail.email}
                    </label>
                  ))}
                </fieldset>
              ) : null}
              <Button color="primary" onClick={handleSendMagicLink} disabled={loading}>
                {loading ? <LoadingSpinner /> : null}
                Send magic link
              </Button>
            </>
          )}
        </section>
      </form>
    </Layout>
  );
}

SubscriptionMagicLinkPage.publicLayout = true;
export default SubscriptionMagicLinkPage;
