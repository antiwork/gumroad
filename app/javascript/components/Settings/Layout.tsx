import cx from "classnames";
import * as React from "react";

import { SettingPage as Page } from "$app/parsers/settings";

import { Button } from "$app/components/Button";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Tabs, Tab } from "$app/components/ui/Tabs";

const PAGE_TITLES = {
  main: "Settings",
  profile: "Profile",
  team: "Team",
  payments: "Payments",
  authorized_applications: "Applications",
  password: "Password",
  third_party_analytics: "Third-party analytics",
  advanced: "Advanced",
};

type Props = {
  onSave?: () => void;
  pages: Page[];
  currentPage: Page;
  children: React.ReactNode;
  hasAside?: boolean;
  canUpdate?: boolean;
};

export const Layout = ({ onSave, pages, currentPage, children, hasAside, canUpdate }: Props) => (
  <>
    <PageHeader
      className="sticky-top"
      title="Settings"
      actions={
        onSave ? (
          <Button color="accent" onClick={onSave} disabled={!canUpdate}>
            Update settings
          </Button>
        ) : null
      }
    >
      <Tabs>
        {pages.map((page) => (
          <Tab key={page} href={Routes[`settings_${page}_path`]()} isSelected={currentPage === page}>
            {PAGE_TITLES[page]}
          </Tab>
        ))}
      </Tabs>
    </PageHeader>
    <div className={cx({ squished: hasAside })}>{children}</div>
  </>
);
