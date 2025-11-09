import * as React from "react";

import { PageHeader } from "$app/components/ui/PageHeader";
import { TabPills, TabPill } from "$app/components/ui/TabPills";

const pageNames = {
  widgets: "Widgets",
  ping: "Ping",
  api: "API",
};

export const Layout = ({
  currentPage,
  children,
}: {
  currentPage: keyof typeof pageNames;
  children?: React.ReactNode;
}) => (
  <div>
    <PageHeader title={pageNames[currentPage]}>
      <TabPills>
        {Object.entries(pageNames).map(([page, name]) => (
          <TabPill key={page} isSelected={page === currentPage} href={Routes[`${page}_path`]()}>
            {name}
          </TabPill>
        ))}
      </TabPills>
    </PageHeader>
    {children}
  </div>
);
