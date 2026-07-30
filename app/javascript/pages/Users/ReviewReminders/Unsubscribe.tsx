import { Link } from "@inertiajs/react";
import * as React from "react";

import { Layout } from "$app/components/EmailAction/Layout";

// Absent when the visitor arrived with a session rather than from an email link.
function UnsubscribeReviewRemindersPage({ subscribe_url }: { subscribe_url?: string }) {
  return (
    <Layout heading="You will no longer receive review reminder emails.">
      If you wish to resubscribe to all review reminder emails, please click{" "}
      <Link href={subscribe_url ?? Routes.user_subscribe_review_reminders_path()} className="underline">
        here
      </Link>
      .
    </Layout>
  );
}

UnsubscribeReviewRemindersPage.publicLayout = true;
export default UnsubscribeReviewRemindersPage;
