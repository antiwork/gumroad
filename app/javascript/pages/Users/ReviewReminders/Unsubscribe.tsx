import { Link } from "@inertiajs/react";
import * as React from "react";

import { Layout } from "$app/components/EmailAction/Layout";

function UnsubscribeReviewRemindersPage() {
  return (
    <Layout heading="You will no longer receive review reminder emails.">
      If you wish to resubscribe to all review reminder emails, please click{" "}
      <Link href={Routes.user_subscribe_review_reminders_path()} className="underline">
        here
      </Link>
      .
    </Layout>
  );
}

UnsubscribeReviewRemindersPage.publicLayout = true;
export default UnsubscribeReviewRemindersPage;
