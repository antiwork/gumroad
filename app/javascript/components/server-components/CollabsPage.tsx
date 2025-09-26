import * as React from "react";
import { createCast } from "ts-safe-cast";

import { Membership, Product } from "$app/data/collabs";
import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";
import { register } from "$app/utils/serverComponentUtil";

import { NavigationButton } from "$app/components/Button";
import { PaginationProps } from "$app/components/Pagination";
import { ProductsLayout } from "$app/components/ProductsLayout";
import { CollabsMembershipsTable } from "$app/components/ProductsPage/Collabs/MembershipsTable";
import { CollabsProductsTable } from "$app/components/ProductsPage/Collabs/ProductsTable";
import { Stats as StatsComponent } from "$app/components/Stats";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { WithTooltip } from "$app/components/WithTooltip";

import placeholder from "$assets/images/placeholders/affiliated.png";

const CollabsPage = ({
  memberships,
  memberships_pagination: membershipsPagination,
  products,
  products_pagination: productsPagination,
  stats,
  archived_tab_visible: archivedTabVisible,
  collaborators_disabled_reason: collaboratorsDisabledReason,
}: {
  memberships: Membership[];
  memberships_pagination: PaginationProps;
  products: Product[];
  products_pagination: PaginationProps;
  stats: {
    total_revenue: number;
    total_customers: number;
    total_members: number;
    total_collaborations: number;
  };
  archived_tab_visible: boolean;
  collaborators_disabled_reason: string | null;
}) => {
  const userAgentInfo = useUserAgentInfo();

  return (
    <ProductsLayout selectedTab="collabs" title="Products" archivedTabVisible={archivedTabVisible}>
      <section className="p-4 md:p-8">
        {memberships.length === 0 && products.length === 0 ? (
          <div className="placeholder">
            <figure>
              <img src={placeholder} />
            </figure>
            <h2>Create your first collab!</h2>
            Offer a product in collaboration with another Gumroad creator to grow your audience.
            <WithTooltip position="top" tip={collaboratorsDisabledReason}>
              <NavigationButton
                disabled={collaboratorsDisabledReason !== null}
                href="/collaborators/new"
                color="accent"
              >
                Add a collab
              </NavigationButton>
            </WithTooltip>
            <p>
              or{" "}
              <a href="/help/article/341-collaborations" target="_blank" rel="noreferrer">
                learn more to get started
              </a>
            </p>
          </div>
        ) : (
          <div style={{ display: "grid", gap: "var(--spacer-7)" }}>
            <div className="stats-grid" aria-label="Stats">
              <StatsComponent
                title="Total revenue"
                description="Gross sales from all your product collabs."
                value={formatPriceCentsWithCurrencySymbol("usd", stats.total_revenue, { symbolFormat: "short" })}
              />
              <StatsComponent
                title="Customers"
                description="Unique customers across all your product collabs."
                value={stats.total_customers.toLocaleString(userAgentInfo.locale)}
              />
              <StatsComponent
                title="Active members"
                description="Members with an active subscription from your product collabs."
                value={stats.total_members.toLocaleString(userAgentInfo.locale)}
              />
              <StatsComponent
                title="Collaborations"
                description="Total number of product collabs."
                value={stats.total_collaborations.toLocaleString(userAgentInfo.locale)}
              />
            </div>
            <div style={{ display: "grid", gap: "var(--spacer-7)" }}>
              {memberships.length ? (
                <CollabsMembershipsTable entries={memberships} pagination={membershipsPagination} />
              ) : null}

              {products.length ? <CollabsProductsTable entries={products} pagination={productsPagination} /> : null}
            </div>
          </div>
        )}
      </section>
    </ProductsLayout>
  );
};

export default register({ component: CollabsPage, propParser: createCast() });
