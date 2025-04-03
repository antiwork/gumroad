import cx from "classnames";
import * as React from "react";

import { SettingPage as Page } from "$app/parsers/settings";

import { Button } from "$app/components/Button";

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
const Tab = ({ page, isCurrent }: { page: Page; isCurrent: boolean }) => (
  <a role="tab" href={Routes[`settings_${page}_path`]()} aria-selected={isCurrent}>
    {PAGE_TITLES[page]}
  </a>
);

export const Layout = ({ onSave, pages, currentPage, children, hasAside, canUpdate }: Props) => (
  <>
    <header className="sticky-top">
      <h1>Settings</h1>
      {onSave ? (
        <div className="actions">
          <Button color="accent" onClick={onSave} disabled={!canUpdate}>
            Update settings
          </Button>
        </div>
      ) : null}
      <div role="tablist">
        {pages.map((page) => (
          <Tab page={page} key={page} isCurrent={currentPage === page} />
        ))}
      </div>
    </header>
    <main className={cx({ squished: hasAside })}>{children}</main>
  </>
);
