import { Head } from "@inertiajs/react";

import { Card, CardContent } from "$app/components/ui/Card";
import { useDomains } from "$app/components/DomainSettings";

const SubscribeReviewReminders = () => {
  const { rootDomain } = useDomains();

  return (
    <>
      <Head title="Subscribed to Review Reminders" />
      <Card>
        <CardContent asChild>
          <header>
            <h2 className="grow">Review reminders enabled</h2>
          </header>
        </CardContent>
        <CardContent asChild>
          <p>You will start receiving review reminders for all purchases again.</p>
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

export default SubscribeReviewReminders;
