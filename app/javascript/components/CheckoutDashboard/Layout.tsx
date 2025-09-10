import cx from "classnames";
import * as React from "react";

import { PageHeader } from "$app/components/ui/PageHeader";
import { Tabs, Tab } from "$app/components/ui/Tabs";

const pageNames = {
  discounts: "Discounts",
  form: "Checkout form",
  upsells: "Upsells",
};
export type Page = keyof typeof pageNames;

export const Layout = ({
  currentPage,
  children,
  pages,
  actions,
  hasAside,
}: {
  currentPage: Page;
  children: React.ReactNode;
  pages: Page[];
  actions?: React.ReactNode;
  hasAside?: boolean;
}) =>
  hasAside ? (
    <>
      <Header actions={actions} pages={pages} currentPage={currentPage} sticky />
      <div className="squished">{children}</div>
    </>
  ) : (
    <div>
      <Header actions={actions} pages={pages} currentPage={currentPage} />
      {children}
    </div>
  );

const Header = ({
  actions,
  pages,
  currentPage,
  sticky,
}: {
  currentPage: Page;
  pages: Page[];
  actions?: React.ReactNode;
  sticky?: boolean;
}) => (
  <PageHeader className={cx({ "sticky-top": sticky })} title="Checkout" actions={actions}>
    <Tabs>
      {pages.map((page) => (
        <Tab key={page} href={Routes[`checkout_${page}_path`]()} isSelected={page === currentPage}>
          {pageNames[page]}
        </Tab>
      ))}
    </Tabs>
  </PageHeader>
);
