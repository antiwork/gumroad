import { Head } from "@inertiajs/react";
import * as React from "react";

import { Layout } from "$app/components/EmailAction/Layout";

const Subscribe = () => (
  <>
    <Head title="Subscribe to review reminders" />
    <Layout heading="Review reminders enabled">
      You will start receiving review reminders for all purchases again.
    </Layout>
  </>
);

export default Subscribe;
