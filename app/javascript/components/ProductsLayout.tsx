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
        <Tab isSelected={selectedTab === "products"} href={Routes.products_path()}>
          All products
        </Tab>

        <Tab isSelected={selectedTab === "affiliated"} href={Routes.products_affiliated_index_path()}>
          Affiliated
        </Tab>

        <Tab isSelected={selectedTab === "collabs"} href={Routes.products_collabs_path()}>
          Collabs
        </Tab>

        {archivedTabVisible ? (
          <Tab isSelected={selectedTab === "archived"} href={Routes.products_archived_index_path()}>
            Archived
          </Tab>
        ) : null}
      </Tabs>
    </PageHeader>
    {children}
  </div>
);
