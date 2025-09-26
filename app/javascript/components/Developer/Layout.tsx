import * as React from "react";

import { PageHeader } from "$app/components/ui/PageHeader";
import { Tabs, Tab } from "$app/components/ui/Tabs";

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
      <Tabs>
        {Object.entries(pageNames).map(([page, name]) => (
          <Tab key={page} isSelected={page === currentPage} href={Routes[`${page}_path`]()}>
            {name}
          </Tab>
        ))}
      </Tabs>
    </PageHeader>
    {children}
  </div>
);
