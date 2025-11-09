import * as React from "react";

import { assertDefined } from "$app/utils/assert";

import { useLoggedInUser } from "$app/components/LoggedInUser";
import { PageHeader } from "$app/components/ui/PageHeader";
import { TabPills, TabPill } from "$app/components/ui/TabPills";

export const AnalyticsLayout = ({
  selectedTab,
  children,
  actions,
}: {
  selectedTab: "following" | "sales" | "utm_links";
  children: React.ReactNode;
  actions?: React.ReactNode;
}) => {
  const user = assertDefined(useLoggedInUser());

  return (
    <div>
      <PageHeader title="Analytics" actions={actions}>
        <TabPills>
          <TabPill href={Routes.audience_dashboard_path()} isSelected={selectedTab === "following"}>
            Following
          </TabPill>
          <TabPill href={Routes.sales_dashboard_path()} isSelected={selectedTab === "sales"}>
            Sales
          </TabPill>
          {user.policies.utm_link.index ? (
            <TabPill href={Routes.utm_links_dashboard_path()} isSelected={selectedTab === "utm_links"}>
              Links
            </TabPill>
          ) : null}
        </TabPills>
      </PageHeader>
      {children}
    </div>
  );
};
