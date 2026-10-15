import { Link } from "@inertiajs/react";
import * as React from "react";

import { PageHeader } from "$app/components/ui/PageHeader";
import { Tabs, Tab } from "$app/components/ui/Tabs";

const pageNames = {
  discounts: "Discounts",
  form: "Checkout form",
  upsells: "Upsells",
};
export type Page = keyof typeof pageNames;

const pagePaths: Record<Page, () => string> = {
  discounts: () => Routes.checkout_discounts_path(),
  form: () => Routes.checkout_form_path(),
  upsells: () => Routes.checkout_upsells_path(),
};

export const Layout = ({
  currentPage,
  children,
  pages,
  actions,
}: {
  currentPage: Page;
  children: React.ReactNode;
  pages: Page[];
  actions?: React.ReactNode;
}) => (
  <div>
    <Header actions={actions} pages={pages} currentPage={currentPage} />
    {children}
  </div>
);

const Header = ({ actions, pages, currentPage }: { currentPage: Page; pages: Page[]; actions?: React.ReactNode }) => (
  <PageHeader title="Checkout" actions={actions}>
    <Tabs>
      {pages.map((page) => (
        <Tab key={page} isSelected={page === currentPage} asChild>
          <Link href={pagePaths[page]()} className="no-underline">
            {pageNames[page]}
          </Link>
        </Tab>
      ))}
    </Tabs>
  </PageHeader>
);
