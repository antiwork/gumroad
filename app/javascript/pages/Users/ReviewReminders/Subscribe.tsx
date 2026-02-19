import * as React from "react";

import { Layout } from "$app/components/EmailAction/Layout";

function SubscribeReviewRemindersPage() {
  return (
    <Layout heading="Review reminders enabled">
      You will start receiving review reminders for all purchases again.
    </Layout>
  );
}

SubscribeReviewRemindersPage.publicLayout = true;
export default SubscribeReviewRemindersPage;
