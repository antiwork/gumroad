import * as React from "react";

import { assertDefined } from "$app/utils/assert";

import { useLoggedInUser } from "$app/components/LoggedInUser";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Tabs, Tab } from "$app/components/ui/Tabs";

export const AnalyticsLayout = ({
  selectedTab,
  children,
  actions,
  title = "Analytics",
  showTabs = true,
}: {
  selectedTab: "following" | "sales" | "utm_links";
  children: React.ReactNode;
  actions?: React.ReactNode;
  title?: string;
  showTabs?: boolean;
}) => {
  const user = assertDefined(useLoggedInUser());

  return (
    <div>
      <PageHeader title={title} actions={actions}>
        {showTabs ? (
          <Tabs>
            <Tab href={Routes.audience_dashboard_path()} isSelected={selectedTab === "following"}>
              Following
            </Tab>
            <Tab href={Routes.sales_dashboard_path()} isSelected={selectedTab === "sales"}>
              Sales
            </Tab>
            {user.policies.utm_link.index ? (
              <Tab href={Routes.dashboard_utm_links_path()} isSelected={selectedTab === "utm_links"}>
                Links
              </Tab>
            ) : null}
          </Tabs>
        ) : null}
      </PageHeader>
      {children}
    </div>
  );
};
