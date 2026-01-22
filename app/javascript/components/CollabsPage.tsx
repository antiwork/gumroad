import * as React from "react";

import { Membership, Product } from "$app/data/collabs";
import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

import { NavigationButtonInertia } from "$app/components/NavigationButton";
import { PaginationProps } from "$app/components/Pagination";
import { ProductsLayout } from "$app/components/ProductsLayout";
import { CollabsMembershipsTable } from "$app/components/ProductsPage/Collabs/MembershipsTable";
import { CollabsProductsTable } from "$app/components/ProductsPage/Collabs/ProductsTable";
import { Stats as StatsComponent } from "$app/components/Stats";
import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { WithTooltip } from "$app/components/WithTooltip";

import placeholder from "$assets/images/placeholders/affiliated.png";

export type CollabsPageProps = {
  products_data: {
    products: Product[];
    pagination: PaginationProps;
  };
  memberships_data: {
    memberships: Membership[];
    pagination: PaginationProps;
  };
  stats: {
    total_revenue: number;
    total_customers: number;
    total_members: number;
    total_collaborations: number;
  };
  archived_tab_visible: boolean;
  collaborators_disabled_reason: string | null;
};

const CollabsPage = ({
  products_data: { products, pagination: productsPagination },
  memberships_data: { memberships, pagination: membershipsPagination },
  stats,
  archived_tab_visible: archivedTabVisible,
  collaborators_disabled_reason: collaboratorsDisabledReason,
}: CollabsPageProps) => {
  const userAgentInfo = useUserAgentInfo();

  return (
    <ProductsLayout selectedTab="collabs" title="Sản phẩm" archivedTabVisible={archivedTabVisible}>
      <section className="p-4 md:p-8">
        {memberships.length === 0 && products.length === 0 ? (
          <Placeholder>
            <PlaceholderImage src={placeholder} />
            <h2>Tạo cộng tác đầu tiên của bạn!</h2>
            Cung cấp một sản phẩm hợp tác với một người sáng tạo Gumroad khác để phát triển khán giả của bạn.
            <WithTooltip position="top" tip={collaboratorsDisabledReason}>
              <NavigationButtonInertia
                disabled={collaboratorsDisabledReason !== null}
                href="/collaborators/new"
                color="accent"
              >
                Thêm cộng tác
              </NavigationButtonInertia>
            </WithTooltip>
            <p>
              hoặc{" "}
              <a href="/help/article/341-collaborations" target="_blank" rel="noreferrer">
                tìm hiểu thêm để bắt đầu
              </a>
            </p>
          </Placeholder>
        ) : (
          <div style={{ display: "grid", gap: "var(--spacer-7)" }}>
            <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4" aria-label="Stats">
              <StatsComponent
                title="Tổng doanh thu"
                description="Tổng doanh số từ tất cả các cộng tác sản phẩm của bạn."
                value={formatPriceCentsWithCurrencySymbol("usd", stats.total_revenue, { symbolFormat: "short" })}
              />
              <StatsComponent
                title="Khách hàng"
                description="Khách hàng duy nhất trên tất cả các cộng tác sản phẩm của bạn."
                value={stats.total_customers.toLocaleString(userAgentInfo.locale)}
              />
              <StatsComponent
                title="Thành viên đang hoạt động"
                description="Các thành viên có đăng ký đang hoạt động từ các cộng tác sản phẩm của bạn."
                value={stats.total_members.toLocaleString(userAgentInfo.locale)}
              />
              <StatsComponent
                title="Cộng tác"
                description="Tổng số cộng tác sản phẩm."
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

export default CollabsPage;
