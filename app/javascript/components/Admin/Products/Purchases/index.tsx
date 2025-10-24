import * as React from "react";
import { cast } from "ts-safe-cast";

import { useLazyPaginatedFetch } from "$app/hooks/useLazyFetch";

import AdminProductPurchasesContent from "./Content";
import { type ProductPurchase } from "./Purchase";

type AdminProductPurchasesProps = {
  product_id: number;
  is_affiliate_user?: boolean;
  user_id: number | null;
};

const AdminProductPurchases = ({ product_id, is_affiliate_user = false, user_id }: AdminProductPurchasesProps) => {
  const [open, setOpen] = React.useState(false);

  const urlParams = { format: "json" };
  const url =
    user_id && is_affiliate_user
      ? Routes.admin_user_product_purchases_path(user_id, product_id, urlParams)
      : Routes.admin_product_purchases_path(product_id, urlParams);

  const {
    data: purchases,
    isLoading,
    fetchData: fetchPurchases,
    hasMore,
    pagination,
    setData: setPurchases,
    setHasMore,
    setHasLoaded,
    setIsLoading,
  } = useLazyPaginatedFetch<ProductPurchase[]>([], {
    url,
    responseParser: (data) => {
      const parsed = cast<{ purchases: ProductPurchase[] }>(data);
      return parsed.purchases;
    },
    mode: "append",
  });

  const fetchNextPage = () => {
    if (purchases.length >= pagination.limit) {
      void fetchPurchases({ page: pagination.page + 1 });
    }
  };

  const resetPurchases = () => {
    setPurchases([]);
    setHasLoaded(false);
    setHasMore(true);
    setIsLoading(true);
  };

  const onToggle = (e: React.MouseEvent<HTMLDetailsElement>) => {
    setOpen(e.currentTarget.open);
    if (e.currentTarget.open) {
      void fetchPurchases();
    } else {
      resetPurchases();
    }
  };

  return (
    <>
      <hr />
      <details open={open} onToggle={onToggle}>
        <summary>
          <h3>{is_affiliate_user ? "Affiliate purchases" : "Purchases"}</h3>
        </summary>
        <AdminProductPurchasesContent
          purchases={purchases}
          isLoading={isLoading}
          hasMore={hasMore}
          onLoadMore={fetchNextPage}
        />
      </details>
    </>
  );
};

export default AdminProductPurchases;
