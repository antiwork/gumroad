import { Head } from "@inertiajs/react";
import * as React from "react";

import { Layout } from "$app/components/EmailAction/Layout";

const Unsubscribe = () => (
  <>
    <Head title="Unsubscribe from review reminders" />
    <Layout heading="You will no longer receive review reminder emails.">
      If you wish to resubscribe to all review reminder emails, please click{" "}
      <a href={Routes.user_subscribe_review_reminders_path()}>here</a>.
    </Layout>
  </>
);

export default Unsubscribe;
