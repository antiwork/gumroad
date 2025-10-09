import * as React from "react";
import { createCast } from "ts-safe-cast";

import { SettingPage } from "$app/parsers/settings";
import { register } from "$app/utils/serverComponentUtil";

import ApplicationForm from "$app/components/Settings/AdvancedPage/ApplicationForm";
import { Layout } from "$app/components/Settings/Layout";

export type Application = {
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
const EditApplicationPage = ({ settings_pages, application }: Props) => (
  <Layout currentPage="advanced" pages={settings_pages}>
    <form>
      <section className="p-4! md:p-8!">
        <header>
          <h2>Edit application</h2>
        </header>
        <ApplicationForm application={application} />
      </section>
    </form>
  </Layout>
);

export default register({ component: EditApplicationPage, propParser: createCast() });
