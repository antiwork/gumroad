import { Link } from "@inertiajs/react";
import cx from "classnames";
import * as React from "react";

import { PageHeader } from "$app/components/ui/PageHeader";
import { TabPills, TabPill } from "$app/components/ui/TabPills";

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
    <TabPills>
      {pages.map((page) => (
        <TabPill key={page} isSelected={page === currentPage} asChild>
          <Link href={Routes[`checkout_${page}_path`]()} className="no-underline">
            {pageNames[page]}
          </Link>
        </TabPill>
      ))}
    </TabPills>
  </PageHeader>
);
