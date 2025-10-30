import * as React from "react";
import { cast } from "ts-safe-cast";

import { useLazyPaginatedFetch } from "$app/hooks/useLazyFetch";

import AdminProductPurchasesContent from "./Content";
import { type ProductPurchase } from "./Purchase";

type AdminProductPurchasesProps = {
  product_id: number;
  isAffiliateUser?: boolean;
  user_id: number | null;
};

const AdminProductPurchases = ({ product_id, isAffiliateUser = false, user_id }: AdminProductPurchasesProps) => {
  const [open, setOpen] = React.useState(false);

  const url =
    user_id && isAffiliateUser
      ? Routes.admin_affiliate_product_purchases_path(user_id, product_id, { format: "json" })
      : Routes.admin_product_purchases_path(product_id, { format: "json" });

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
          <h3>{isAffiliateUser ? "Affiliate purchases" : "Purchases"}</h3>
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
