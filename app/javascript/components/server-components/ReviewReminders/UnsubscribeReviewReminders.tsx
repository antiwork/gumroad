import * as React from "react";

import { register } from "$app/utils/serverComponentUtil";

import { Layout } from "$app/components/EmailAction/Layout";

const UnsubscribeReviewReminders = () => (
  <Layout heading="You will no longer receive review reminder emails.">
    If you wish to resubscribe to all review reminder emails, please click{" "}
    <a href={Routes.user_subscribe_review_reminders_url()}>here</a>.
  </Layout>
);

export default register({ component: UnsubscribeReviewReminders, propParser: () => ({}) });
