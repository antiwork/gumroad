import { useForm } from "@inertiajs/react";
import * as React from "react";

import { Button } from "$app/components/Button";
import { Layout } from "$app/components/EmailAction/Layout";

type Props = { unsubscribe_url: string | null; unsubscribed: boolean };

function UnsubscribeFeatureAnnouncementsPage({ unsubscribe_url, unsubscribed }: Props) {
  const form = useForm({});

  if (unsubscribed || !unsubscribe_url) {
    return (
      <Layout heading="You will no longer receive feature announcement emails.">
        You can turn them back on anytime from your notification settings.
      </Layout>
    );
  }

  return (
    <Layout heading="Unsubscribe from feature announcements?">
      You will stop receiving emails about new Gumroad features. Other emails are not affected.{" "}
      <Button color="primary" disabled={form.processing} onClick={() => form.post(unsubscribe_url)}>
        Unsubscribe
      </Button>
    </Layout>
  );
}

UnsubscribeFeatureAnnouncementsPage.publicLayout = true;
export default UnsubscribeFeatureAnnouncementsPage;
