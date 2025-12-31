import { Link } from "@inertiajs/react";
import * as React from "react";

import { assertDefined } from "$app/utils/assert";

import { useLoggedInUser } from "$app/components/LoggedInUser";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Tabs, Tab } from "$app/components/ui/Tabs";

export const AnalyticsLayout = ({
  title,
  selectedTab,
  children,
  actions,
  showTabs,
}: {
  title: string;
  selectedTab: "following" | "sales" | "utm_links";
  children: React.ReactNode;
  actions?: React.ReactNode;
  showTabs?: boolean;
}) => {
  const user = assertDefined(useLoggedInUser());

  return (
    <div>
      <PageHeader title={title} actions={actions}>
        {showTabs ? (
          <Tabs>
            <Tab isSelected={selectedTab === "following"} asChild>
              <Link href={Routes.audience_dashboard_path()}>Following</Link>
            </Tab>
            <Tab isSelected={selectedTab === "sales"} asChild>
              <Link href={Routes.sales_dashboard_path()}>Sales</Link>
            </Tab>
            {user.policies.utm_link.index ? (
              <Tab isSelected={selectedTab === "utm_links"} asChild>
                <Link href={Routes.dashboard_utm_links_path()}>Links</Link>
              </Tab>
            ) : null}
          </Tabs>
        ) : null}
      </PageHeader>
      {children}
    </div>
  );
};
