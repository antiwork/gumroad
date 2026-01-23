import { Head, Link } from "@inertiajs/react";
import React from "react";

import { Card, CardContent } from "$app/components/ui/Card";

const UnsubscribeReviewReminders = () => (
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
          <Link href={Routes.user_subscribe_review_reminders_path()}>here</Link>.
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
      <Link href={Routes.root_path()} className="logo-full" aria-label="Gumroad" />
    </footer>
  </>
);

UnsubscribeReviewReminders.disableLayout = true;
export default UnsubscribeReviewReminders;
