import cx from "classnames";
import * as React from "react";

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
      <main className="squished">{children}</main>
    </>
  ) : (
    <main>
      <Header actions={actions} pages={pages} currentPage={currentPage} />
      {children}
    </main>
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
  <header className={cx({ "sticky-top": sticky })}>
    <h1>Checkout</h1>
    {actions ? <div className="actions">{actions}</div> : null}
    <div role="tablist">
      {pages.map((page) => (
        <a key={page} role="tab" href={Routes[`checkout_${page}_path`]()} aria-selected={page === currentPage}>
          {pageNames[page]}
        </a>
      ))}
    </div>
  </header>
);
