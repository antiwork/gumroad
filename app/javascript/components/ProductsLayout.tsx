import { Link } from "@inertiajs/react";
import * as React from "react";

import { PageHeader } from "$app/components/ui/PageHeader";
import { Tab, Tabs } from "$app/components/ui/Tabs";

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
  <div>
    <PageHeader title={title || "Products"} actions={ctaButton}>
      <Tabs>
        <Tab isSelected={selectedTab === "products"} asChild>
          <Link className="no-underline" href={Routes.products_path()}>
            All products
          </Link>
        </Tab>

        <Tab isSelected={selectedTab === "affiliated"} asChild>
          <Link className="no-underline" href={Routes.products_affiliated_index_path()}>
            Affiliated
          </Link>
        </Tab>

        <Tab isSelected={selectedTab === "collabs"} asChild>
          <Link className="no-underline" href={Routes.products_collabs_path()}>
            Collabs
          </Link>
        </Tab>

        {archivedTabVisible ? (
          <Tab isSelected={selectedTab === "archived"} asChild>
            <Link className="no-underline" href={Routes.products_archived_index_path()}>
              Archived
            </Link>
          </Tab>
        ) : null}
      </Tabs>
    </PageHeader>
    {children}
  </div>
);
