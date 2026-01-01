import { Link } from "@inertiajs/react";
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
            <Tab asChild isSelected={selectedTab === "following"}>
              <Link href={Routes.audience_dashboard_path()}>Following</Link>
            </Tab>
            <Tab asChild isSelected={selectedTab === "sales"}>
              <Link href={Routes.sales_dashboard_path()}>Sales</Link>
            </Tab>
            {user.policies.utm_link.index ? (
              <Tab asChild isSelected={selectedTab === "utm_links"}>
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
