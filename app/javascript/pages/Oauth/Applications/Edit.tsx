import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { SettingPage } from "$app/parsers/settings";

import ApplicationForm from "$app/components/Settings/AdvancedPage/ApplicationForm";
import { Layout } from "$app/components/Settings/Layout";
import { FormSection } from "$app/components/ui/FormSection";

type Application = {
  id: string;
  name: string;
  redirect_uri: string;
  icon_url: string | null;
  uid: string;
  secret: string;
};

type Props = {
  settings_pages: SettingPage[];
  application: Application;
};

export default function EditApplicationPage() {
  const props = cast<Props>(usePage().props);

  return (
    <Layout currentPage="advanced" pages={props.settings_pages}>
      <form>
        <FormSection header={<h2>Edit application</h2>}>
          <ApplicationForm application={props.application} />
        </FormSection>
      </form>
    </Layout>
  );
}
