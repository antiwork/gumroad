import { Link, usePage } from "@inertiajs/react";
import * as React from "react";

import { LoggedInUser } from "$app/types/user";

import { HomeFooter } from "$app/components/Home/Shared/Footer";
import { HomeNav } from "$app/components/Home/Shared/Nav";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Tab, Tabs } from "$app/components/ui/Tabs";

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
  children: React.ReactNode;
}) => {
  const { props } = usePage<{ current_user?: LoggedInUser }>();
  return (
    <div className="flex min-h-screen flex-col">
      {props.current_user ? null : (
        <div className="shrink-0">
          <HomeNav />
        </div>
      )}
      <PageHeader title={pageNames[currentPage]}>
        <Tabs>
          <Tab isSelected={currentPage === "widgets"} asChild>
            <Link href={Routes.widgets_path()}>Widgets</Link>
          </Tab>
          <Tab isSelected={currentPage === "ping"} asChild>
            <Link href={Routes.ping_path()}>Ping</Link>
          </Tab>
          <Tab isSelected={currentPage === "api"} asChild>
            <Link href={Routes.api_path()}>API</Link>
          </Tab>
        </Tabs>
      </PageHeader>
      {children}
      {props.current_user ? null : (
        <div className="mt-auto">
          <HomeFooter />
        </div>
      )}
    </div>
  );
};
