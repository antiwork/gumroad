import * as React from "react";

import { PageHeader } from "$app/components/ui/PageHeader";
import { Tabs, Tab } from "$app/components/ui/Tabs";

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
        <Tabs>
          <Tab href={Routes.collaborators_path()} isSelected={selectedTab === "collaborators"}>
            Collaborators
          </Tab>
          <Tab href={Routes.collaborators_incomings_path()} isSelected={selectedTab === "collaborations"}>
            Collaborations
          </Tab>
        </Tabs>
      ) : null}
    </PageHeader>
    {children}
  </div>
);
