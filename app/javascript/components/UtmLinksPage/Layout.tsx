import { Link } from "@inertiajs/react";
import * as React from "react";

import { assertDefined } from "$app/utils/assert";

import { useLoggedInUser } from "$app/components/LoggedInUser";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Tabs, Tab } from "$app/components/ui/Tabs";

type LayoutProps = {
  title: string;
  actions?: React.ReactNode;
  children: React.ReactNode;
  selectedTab?: "following" | "sales" | "utm_links";
};

export const Layout = ({ title, actions, children, selectedTab = "utm_links" }: LayoutProps) => {
  const user = assertDefined(useLoggedInUser());

  return (
    <div>
      <PageHeader title={title} actions={actions}>
        <Tabs>
          <Tab href={Routes.audience_dashboard_path()} isSelected={selectedTab === "following"} asChild>
            <Link href={Routes.audience_dashboard_path()}>Following</Link>
          </Tab>
          <Tab href={Routes.sales_dashboard_path()} isSelected={selectedTab === "sales"} asChild>
            <Link href={Routes.sales_dashboard_path()}>Sales</Link>
          </Tab>
          {user.policies.utm_link.index ? (
            <Tab href={Routes.utm_links_dashboard_path()} isSelected={selectedTab === "utm_links"} asChild>
              <Link href={Routes.utm_links_dashboard_path()}>Links</Link>
            </Tab>
          ) : null}
        </Tabs>
      </PageHeader>
      {children}
    </div>
  );
};
