import { Link } from "@inertiajs/react";
import * as React from "react";

import { PageHeader } from "$app/components/ui/PageHeader";
import { TabPill, TabPills } from "$app/components/ui/TabPills";

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
      <TabPills>
        <TabPill isSelected={selectedTab === "products"} asChild>
          <Link href={Routes.products_path()} className="no-underline">
            All products
          </Link>
        </TabPill>

        <TabPill isSelected={selectedTab === "affiliated"} asChild>
          <Link href={Routes.products_affiliated_index_path()} className="no-underline">
            Affiliated
          </Link>
        </TabPill>

        <TabPill isSelected={selectedTab === "collabs"} asChild>
          <Link href={Routes.products_collabs_path()} className="no-underline">
            Collabs
          </Link>
        </TabPill>

        {archivedTabVisible ? (
          <TabPill isSelected={selectedTab === "archived"} asChild>
            <Link href={Routes.products_archived_index_path()} className="no-underline">
              Archived
            </Link>
          </TabPill>
        ) : null}
      </TabPills>
    </PageHeader>
    {children}
  </div>
);
