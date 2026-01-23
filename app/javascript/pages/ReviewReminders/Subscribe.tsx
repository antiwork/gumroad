import { Head, Link } from "@inertiajs/react";
import React from "react";

import { Card, CardContent } from "$app/components/ui/Card";

const SubscribeReviewReminders = () => (
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
      <Link href={Routes.root_path()} className="logo-full" aria-label="Gumroad" />
    </footer>
  </>
);

SubscribeReviewReminders.disableLayout = true;
export default SubscribeReviewReminders;
