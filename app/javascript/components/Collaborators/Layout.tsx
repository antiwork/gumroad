import { Link } from "@inertiajs/react";
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
          <Tab asChild isSelected={selectedTab === "collaborators"}>
            <Link href={Routes.collaborators_path()}>Collaborators</Link>
          </Tab>
          <Tab asChild isSelected={selectedTab === "collaborations"}>
            <Link href={Routes.collaborators_incomings_path()}>Collaborations</Link>
          </Tab>
        </Tabs>
      ) : null}
    </PageHeader>
    {children}
  </div>
);
