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
}: {
  selectedTab: "following" | "sales" | "utm_links";
  children: React.ReactNode;
  actions?: React.ReactNode;
}) => {
  const user = assertDefined(useLoggedInUser());

  return (
    <div>
      <PageHeader title="Analytics" actions={actions}>
        <Tabs>
          <Tab isSelected={selectedTab === "following"}>
            <Link className="no-underline" href={Routes.audience_dashboard_path()}>
              Following
            </Link>
          </Tab>
          <Tab isSelected={selectedTab === "sales"}>
            <Link className="no-underline" href={Routes.sales_dashboard_path()}>
              Sales
            </Link>
          </Tab>
          {user.policies.utm_link.index ? (
            <Tab isSelected={selectedTab === "utm_links"}>
              <Link className="no-underline" href={Routes.utm_links_dashboard_path()}>
                Links
              </Link>
            </Tab>
          ) : null}
        </Tabs>
      </PageHeader>
      {children}
    </div>
  );
};
