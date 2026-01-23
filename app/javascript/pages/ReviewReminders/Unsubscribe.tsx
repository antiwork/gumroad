import { Head } from "@inertiajs/react";

import { Card, CardContent } from "$app/components/ui/Card";
import { useDomains } from "$app/components/DomainSettings";

const UnsubscribeReviewReminders = () => {
  const { rootDomain } = useDomains();

  return (
    <>
      <Head title="Unsubscribed from Review Reminders" />
      <Card>
        <CardContent asChild>
          <header>
            <h2 className="grow">You will no longer receive review reminder emails.</h2>
          </header>
        </CardContent>
        <CardContent asChild>
          <p>
            If you wish to resubscribe to all review reminder emails, please click{" "}
            <a href={Routes.user_subscribe_review_reminders_url()}>here</a>.
          </p>
        </CardContent>
      </Card>
      <footer
        style={{
          textAlign: "center",
          padding: "var(--spacer-4)",
        }}
      >
        Powered by&ensp;
        <a href={Routes.root_url({ host: rootDomain })} className="logo-full" aria-label="Gumroad" />
      </footer>
    </>
  );
};

export default UnsubscribeReviewReminders;
