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

  const url = Routes.admin_product_purchases_path(product_id, {
    format: "json",
    affiliate_user_id: user_id && is_affiliate_user ? user_id : undefined,
  });

  const {
    data: purchases,
    isLoading,
    fetchNextPage,
    hasMore,
  } = useLazyPaginatedFetch<ProductPurchase[]>([], {
    fetchUnlessLoaded: open,
    url,
    responseParser: (data) => {
      const parsed = cast<{ purchases: ProductPurchase[] }>(data);
      return parsed.purchases;
    },
    mode: "append",
  });

  return (
    <>
      <hr />
      <details open={open} onToggle={(e) => setOpen(e.currentTarget.open)}>
        <summary>
          <h3>{is_affiliate_user ? "Affiliate purchases" : "Purchases"}</h3>
        </summary>
        <AdminProductPurchasesContent
          purchases={purchases}
          isLoading={isLoading}
          hasMore={hasMore}
          onLoadMore={() => void fetchNextPage()}
        />
      </details>
    </>
  );
};

export default AdminProductPurchases;
