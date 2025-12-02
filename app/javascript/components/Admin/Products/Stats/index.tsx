import * as React from "react";
import { cast } from "ts-safe-cast";

import { useLazyFetch } from "$app/hooks/useLazyFetch";

import AdminProductStatsSales, { type AdminProductStatsSalesProps } from "$app/components/Admin/Products/Stats/Sales";
import AdminProductStatsViewCount from "$app/components/Admin/Products/Stats/ViewCount";
import { useIsIntersecting } from "$app/components/useIsIntersecting";

const AdminProductStats = ({ product_external_id }: { product_external_id: string }) => {
  const {
    data: { views_count: viewsCount },
    isLoading: isViewsCountLoading,
    hasLoaded: hasLoadedViewsCount,
    fetchData: fetchViewsCount,
  } = useLazyFetch<{ views_count: number }>(
    { views_count: 0 },
    {
      fetchUnlessLoaded: true,
      url: Routes.views_count_admin_product_path(product_external_id),
      responseParser: (data) => cast<{ views_count: number }>(data),
    },
  );

  const {
    data: { sales_stats: salesStats },
    isLoading: isSalesStatsLoading,
    hasLoaded: hasLoadedSalesStats,
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
      fetchUnlessLoaded: true,
      url: Routes.sales_stats_admin_product_path(product_external_id),
      responseParser: (data) => cast<{ sales_stats: AdminProductStatsSalesProps }>(data),
    },
  );

  const elementRef = useIsIntersecting<HTMLLIElement>((isIntersecting) => {
    if (!isIntersecting) return;
    if (!hasLoadedViewsCount && !isViewsCountLoading) void fetchViewsCount();
    if (!hasLoadedSalesStats && !isSalesStatsLoading) void fetchSalesStats();
  });

  return (
    <>
      <li className="hidden after:hidden" ref={elementRef} />
      <AdminProductStatsViewCount viewsCount={viewsCount} isLoading={isViewsCountLoading} />
      <AdminProductStatsSales salesStats={salesStats} isLoading={isSalesStatsLoading} />
    </>
  );
};

export default AdminProductStats;
