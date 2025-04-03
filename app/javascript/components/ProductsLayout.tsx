import * as React from "react";

export type Tab = "products" | "discover" | "affiliated" | "collabs" | "archived";

export const ProductsLayout = ({
  selectedTab,
  title,
  ctaButton,
  children,
  archivedTabVisible,
}: {
  selectedTab: Tab;
  ctaButton?: React.ReactNode;
  title?: string | undefined;
  children: React.ReactNode;
  archivedTabVisible: boolean;
}) => (
  <main>
    <header>
      <h1>{title || "Products"}</h1>

      {ctaButton ? <div className="actions">{ctaButton}</div> : null}

      <div role="tablist">
        <a aria-selected={selectedTab === "products"} href={Routes.products_path()} role="tab">
          All products
        </a>

        <a aria-selected={selectedTab === "affiliated"} href={Routes.products_affiliated_index_path()} role="tab">
          Affiliated
        </a>

        <a aria-selected={selectedTab === "collabs"} href={Routes.products_collabs_path()} role="tab">
          Collabs
        </a>

        {archivedTabVisible ? (
          <a aria-selected={selectedTab === "archived"} href={Routes.products_archived_index_path()} role="tab">
            Archived
          </a>
        ) : null}
      </div>
    </header>
    {children}
  </main>
);
