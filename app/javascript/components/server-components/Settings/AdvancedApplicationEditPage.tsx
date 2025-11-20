import * as React from "react";

import { SettingPage } from "$app/parsers/settings";

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

export type EditAdvancedSettingsPropsType = {
  settings_pages: SettingPage[];
  application: Application;
};
const EditApplicationPage = ({ settings_pages, application }: EditAdvancedSettingsPropsType) => (
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

export default EditApplicationPage;
