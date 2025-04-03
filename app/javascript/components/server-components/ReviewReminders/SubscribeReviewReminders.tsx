import * as React from "react";

import { register } from "$app/utils/serverComponentUtil";

import { Layout } from "$app/components/EmailAction/Layout";

const SubscribeReviewReminders = () => (
  <Layout heading="Review reminders enabled">You will start receiving review reminders for all purchases again.</Layout>
);

export default register({ component: SubscribeReviewReminders, propParser: () => ({}) });
