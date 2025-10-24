import * as React from "react";
import { cast } from "ts-safe-cast";

import { useLazyFetch } from "$app/hooks/useLazyFetch";

import AdminProductStatsSales, { type AdminProductStatsSalesProps } from "$app/components/Admin/Products/Stats/Sales";
import AdminProductStatsViewCount from "$app/components/Admin/Products/Stats/ViewCount";

const AdminProductStats = ({ product_id }: { product_id: number }) => {
  const {
    data: { views_count: viewsCount },
    isLoading: isViewsCountLoading,
    fetchData: fetchViewsCount,
  } = useLazyFetch<{ views_count: number }>(
    { views_count: 0 },
    {
      url: Routes.admin_product_views_count_path(product_id),
      responseParser: (data) => cast<{ views_count: number }>(data),
    },
  );

  const {
    data: { sales_stats: salesStats },
    isLoading: isSalesStatsLoading,
    fetchData: fetchSalesStats,
  } = useLazyFetch<{ sales_stats: AdminProductStatsSalesProps }>(
    {
      sales_stats: {
        preorder_state: false,
        count: 0,
        stripe_failed_count: 0,
        balance_formatted: "",
      },
    },
    {
      url: Routes.admin_product_sales_stats_path(product_id),
      responseParser: (data) => cast<{ sales_stats: AdminProductStatsSalesProps }>(data),
    },
  );

  React.useEffect(() => {
    void fetchViewsCount();
    void fetchSalesStats();
  }, []);

  return (
    <>
      <AdminProductStatsViewCount viewsCount={viewsCount} isLoading={isViewsCountLoading} />
      <AdminProductStatsSales salesStats={salesStats} isLoading={isSalesStatsLoading} />
    </>
  );
};

export default AdminProductStats;
