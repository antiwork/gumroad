import * as React from "react";

import { PageHeader } from "$app/components/ui/PageHeader";
import { TabPills, TabPill } from "$app/components/ui/TabPills";

type LayoutProps = {
  title: string;
  headerActions?: React.ReactNode;
  children: React.ReactNode;
  selectedTab?: "collaborators" | "collaborations";
  showTabs?: boolean;
};

export const Layout = ({
  title,
  headerActions,
  children,
  selectedTab = "collaborators",
  showTabs = false,
}: LayoutProps) => (
  <div>
    <PageHeader title={title} actions={headerActions}>
      {showTabs ? (
        <TabPills>
          <TabPill href={Routes.collaborators_path()} isSelected={selectedTab === "collaborators"}>
            Collaborators
          </TabPill>
          <TabPill href={Routes.collaborators_incomings_path()} isSelected={selectedTab === "collaborations"}>
            Collaborations
          </TabPill>
        </TabPills>
      ) : null}
    </PageHeader>
    {children}
  </div>
);
