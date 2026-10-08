import { Link } from "@inertiajs/react";
import * as React from "react";

import { PageHeader } from "$app/components/ui/PageHeader";
import { Tab, Tabs } from "$app/components/ui/Tabs";

export type Tab = "products" | "discover" | "affiliated" | "collabs" | "archived" | "piracy_reports";

export const ProductsLayout = ({
  selectedTab,
  title,
  ctaButton,
  children,
  archivedTabVisible,
  piracyReportsTabVisible = false,
}: {
  selectedTab: Tab;
  ctaButton?: React.ReactNode;
  title?: string | undefined;
  children: React.ReactNode;
  archivedTabVisible: boolean;
  piracyReportsTabVisible?: boolean;
}) => (
  <div>
    <PageHeader title={title || "Products"} actions={ctaButton}>
      <Tabs>
        <Tab isSelected={selectedTab === "products"} asChild>
          <Link href={Routes.products_path()} className="no-underline">
            All products
          </Link>
        </Tab>

        <Tab isSelected={selectedTab === "affiliated"} asChild>
          <Link href={Routes.products_affiliated_index_path()} className="no-underline">
            Affiliated
          </Link>
        </Tab>

        <Tab isSelected={selectedTab === "collabs"} asChild>
          <Link href={Routes.products_collabs_path()} className="no-underline">
            Collabs
          </Link>
        </Tab>

        {archivedTabVisible ? (
          <Tab isSelected={selectedTab === "archived"} asChild>
            <Link href={Routes.products_archived_index_path()} className="no-underline">
              Archived
            </Link>
          </Tab>
        ) : null}

        {piracyReportsTabVisible ? (
          <Tab isSelected={selectedTab === "piracy_reports"} asChild>
            <Link href={Routes.piracy_reports_path()} className="no-underline">
              Piracy reports
            </Link>
          </Tab>
        ) : null}
      </Tabs>
    </PageHeader>
    {children}
  </div>
);
